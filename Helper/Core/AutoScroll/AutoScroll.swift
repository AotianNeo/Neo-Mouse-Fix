//
// --------------------------------------------------------------------------
// AutoScroll.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// Windows-style middle-button Auto Scroll: Click (or hold) the middle button, then move the mouse to scroll. The farther the mouse is from where you clicked, the faster it scrolls.
///
/// The state machine and the scroll curve are ported from LinearMouse's `AutoScrollTransformer.swift` (MIT, see `LICENSE-LinearMouse.txt`).
///
/// MMF-specific parts:
/// - Owns two event taps. They are created after `ButtonInputReceiver`'s tap, so they're inserted in front of it.
///     - `buttonTap`   – Other-mouse-button down / up / drag. Enabled whenever Auto Scroll is usable.
///     - `trackingTap` – Pointer movement, left / right clicks, and the scroll wheel. Only enabled while an Auto Scroll interaction is in progress, so we don't add overhead to every click and mouse move.
/// - Both taps run on the main runLoop, like `ButtonInputReceiver`. All state is main-thread-only.
/// - Scroll output is posted at the session level as pixel-based (continuous) events. `Scroll.m` lets continuous events pass through, so MMF's own scroll processing doesn't touch them.
/// - Clicks that we hold back (e.g. a middle click over a link) are re-posted at the HID level, so `ButtonInputReceiver` still sees them and middle-button remaps keep working.
/// - Turned on / off by the `AutoScroll` config dict and by `SwitchMaster` (lockdown, fast user switching, button kill switch).
/// - Adds options on top of LinearMouse's: Smart Auto Scroll, Super Slowdown, Animate Release, and reverse directions. See `AutoScrollConfig.swift`.

import Cocoa

@objc class AutoScroll: NSObject {

    @objc static let shared = AutoScroll()

    // MARK: Constants

    private static let deadZone: Double = 10
    private static let maxScrollStep: Double = 160
    private static let tickInterval: TimeInterval = 1.0 / 60.0
    private static let replayEchoWindow: CFTimeInterval = 0.5
    private static let eventMarker: Int64 = 0x4D4D_4641_5343 /// Written into `eventSourceUserData` of the events we post, so our own taps let them through.
    private static let passThroughModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift] /// Modified clicks (e.g. Command-middle-click) are never turned into Auto Scroll

    // MARK: Types

    private enum Session {
        case toggle
        case hold
        case pendingToggleOrHold
    }

    private struct PendingActivation {
        var anchor: CGPoint
        var current: CGPoint
        var bufferedEvents: [CGEvent]
        var session: Session /// Session to start if the pointer leaves the dead zone before the button is released
    }

    private enum State {
        case idle
        case pending(PendingActivation)
        case active(anchor: CGPoint, current: CGPoint, session: Session)
    }

    private struct ReleaseAnimation {
        var velocity: CGVector
        var startTime: CFTimeInterval
        var duration: CFTimeInterval
    }

    // MARK: State

    private var config = AutoScrollConfig()
    private var allowedBySwitchMaster = false

    private var buttonTap: CFMachPort?
    private var trackingTap: CFMachPort?

    private var state: State = .idle
    private var suppressTriggerUp = false
    private var suppressedExitMouseButton: Int64?
    private var lastReplay: (time: CFTimeInterval, point: CGPoint, sourcePID: Int64, timestamp: CGEventTimestamp)?

    private var timer: DispatchSourceTimer?
    private var lastVelocity = CGVector.zero
    private var subPixelRemainder = CGVector.zero
    private var scrollTarget: ScrollTarget? /// Kept until the release animation is done
    private var releaseAnimation: ReleaseAnimation?

    private lazy var indicatorController = AutoScrollIndicatorWindowController()
    private lazy var accessibilityActivationClassifier = AutoScrollAccessibilityActivationClassifier()

    // MARK: Interface

    @objc func load_Manual() {

        /// Call this after `[ButtonInputReceiver load_Manual]` so our taps are inserted in front of its tap.

        assert(Thread.isMainThread)
        guard buttonTap == nil else { return }

        buttonTap = Self.createTap(types: [.otherMouseDown, .otherMouseUp, .otherMouseDragged])
        trackingTap = Self.createTap(types: [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel])

        if buttonTap == nil || trackingTap == nil {
            DDLogError("AutoScroll: Failed to create event taps")
        }

        updateTaps()
    }

    @objc static func reload() {
        /// Called by `Config` whenever the config changes
        let newConfig = AutoScrollConfig.load()
        onMain { shared.configChanged(newConfig) }
    }

    @objc func setAllowedBySwitchMaster(_ allowed: Bool) {
        Self.onMain {
            guard allowed != self.allowedBySwitchMaster else { return }
            self.allowedBySwitchMaster = allowed
            self.updateTaps()
        }
    }

    // MARK: Enabling

    private var isRunning: Bool {
        return config.isUsable && allowedBySwitchMaster
    }

    private func configChanged(_ newConfig: AutoScrollConfig) {

        guard newConfig != config else { return }

        DDLogInfo("AutoScroll: Config changed: \(newConfig)")

        deactivate()
        stopReleaseAnimation()
        config = newConfig
        updateTaps()
    }

    private func updateTaps() {

        let running = isRunning

        if !running {
            deactivate()
            stopReleaseAnimation()
            suppressedExitMouseButton = nil
        }

        if let buttonTap {
            CGEvent.tapEnable(tap: buttonTap, enable: running)
        }
        updateTrackingTap()

        DDLogDebug("AutoScroll: Taps updated - running: \(running)")
    }

    private func updateTrackingTap() {

        guard let trackingTap else { return }

        let needed = isRunning && (!isIdle || suppressedExitMouseButton != nil)
        if CGEvent.tapIsEnabled(tap: trackingTap) != needed {
            CGEvent.tapEnable(tap: trackingTap, enable: needed)
        }
    }

    private static func createTap(types: [CGEventType]) -> CFMachPort? {

        /// Same location and placement as `ButtonInputReceiver`. Runs on the main runLoop and starts out disabled.
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        return ModificationUtility.createEventTap(with: .cghidEventTap, mask: mask, option: .defaultTap, placement: .headInsertEventTap, callback: { _, type, event, _ in
            return AutoScroll.shared.handle(type: type, event: event)
        }).takeUnretainedValue() /// Never released. The taps live as long as the Helper.
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

        let passThrough = Unmanaged.passUnretained(event)

        /// Re-enable on timeout
        if type == .tapDisabledByTimeout {
            DDLogInfo("AutoScroll: Event tap was disabled by timeout. Re-enabling.")
            deactivate(replayPendingClick: false) /// We might have missed a button-up (it passed through while we were timed out). Replaying the held-back button-down now would leave the button stuck in the app.
            updateTaps()
            return passThrough
        }
        if type == .tapDisabledByUserInput {
            return passThrough /// We also get this every time we disable the tracking tap ourselves
        }

        /// Guard running
        guard isRunning else { return passThrough }

        /// Let our own events through
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker {
            return passThrough
        }

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let isTrigger = Self.isOtherMouseEvent(type) && button == config.cgButtonNumber

        /// Clicking another button while we're holding back a click -> Deliver the held-back click, then this one
        if case .pending = state, Self.isMouseDown(type), !isTrigger {
            replayPendingActivation(including: event)
            return nil
        }

        /// Clicking another button ends a toggle session. That click is swallowed.
        if case let .active(_, _, session) = state, session == .toggle, Self.isMouseDown(type), !isTrigger {
            suppressedExitMouseButton = button
            deactivate()
            return nil
        }
        if let suppressedExitMouseButton, Self.isMouseUp(type), button == suppressedExitMouseButton {
            self.suppressedExitMouseButton = nil
            updateTrackingTap()
            return nil
        }

        /// Using the scroll wheel ends a toggle session
        if type == .scrollWheel {
            if case let .active(_, _, session) = state, session == .toggle {
                deactivate()
            }
            return passThrough
        }

        /// Main logic
        if isTrigger && type == .otherMouseDown {
            return handleTriggerDown(event)
        }
        if isTrigger && type == .otherMouseUp {
            return handleTriggerUp(event)
        }
        if (isTrigger && type == .otherMouseDragged) || type == .mouseMoved {
            return handlePointerMoved(event, isTriggerDrag: type == .otherMouseDragged)
        }

        return passThrough
    }

    private func handleTriggerDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {

        let passThrough = Unmanaged.passUnretained(event)
        let point = event.location

        /// Clicking again ends a toggle session
        if case let .active(_, _, session) = state, session == .toggle {
            deactivate()
            suppressTriggerUp = true
            return nil
        }

        /// Guard idle
        ///     Shouldn't happen, since the button is already down in all other states.
        guard isIdle else { return passThrough }

        /// Let the MMF settings capture the button
        if Remap.addModeIsEnabled { return passThrough }

        /// Let echoes of our replayed clicks through
        ///     Other tools that hold back and re-post middle clicks (e.g. Smooze Pro's or LinearMouse's own Auto Scroll) can send our replayed click right back to us – without our marker.
        ///     Holding it back again would make the two tools bounce the click back and forth forever. (Observed with Smooze Pro: ~1.7k clicks per second.)
        ///     An echo is either a new event posted by another process (Smooze Pro does this), or a copy of our replayed event (same timestamp).
        ///     A quick second click by the user comes from the same source as the first one and has a new timestamp, so it's still handled normally.
        if let lastReplay,
           CACurrentMediaTime() - lastReplay.time < Self.replayEchoWindow,
           !Self.exceedsDeadZone(from: lastReplay.point, to: point),
           event.getIntegerValueField(.eventSourceUnixProcessID) != lastReplay.sourcePID || (event.timestamp != 0 && event.timestamp == lastReplay.timestamp) {
            DDLogDebug("AutoScroll: Letting echoed click through (source pid: \(event.getIntegerValueField(.eventSourceUnixProcessID)))")
            return passThrough
        }

        /// Let modified clicks through
        if !event.flags.intersection(Self.passThroughModifiers).isEmpty { return passThrough }

        /// Hold only -> Wait for movement. If there is none, it's a normal click.
        if !config.clickToToggle {
            beginPendingActivation(with: event, session: .hold)
            return nil
        }

        let session: Session = config.holdToActivate ? .pendingToggleOrHold : .toggle

        /// Over a link / outside of a scrollable area -> Wait for movement. If there is none, it's a normal click.
        if shouldPreferNativeClick(at: point) {
            beginPendingActivation(with: event, session: session)
            return nil
        }

        /// Start Auto Scroll right away
        activate(anchor: point, current: point, session: session)
        suppressTriggerUp = true
        return nil
    }

    private func handleTriggerUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {

        /// No movement while pending -> It was a normal click
        if case .pending = state {
            replayPendingActivation(including: event)
            return nil
        }

        guard suppressTriggerUp else { return Unmanaged.passUnretained(event) }
        suppressTriggerUp = false

        if case let .active(anchor, current, session) = state {
            switch session {
            case .hold:
                deactivate()
            case .pendingToggleOrHold:
                if Self.exceedsDeadZone(from: anchor, to: current) {
                    deactivate() /// Was dragged -> hold
                } else {
                    state = .active(anchor: anchor, current: current, session: .toggle) /// Was clicked -> toggle
                }
            case .toggle:
                break
            }
        }

        return nil
    }

    private func handlePointerMoved(_ event: CGEvent, isTriggerDrag: Bool) -> Unmanaged<CGEvent>? {

        let passThrough = Unmanaged.passUnretained(event)
        let point = event.location

        switch state {
        case .idle:
            return passThrough

        case var .pending(pending):

            guard isTriggerDrag else { return passThrough }

            pending.current = point
            state = .pending(pending)

            /// Left the dead zone -> Start Auto Scroll. The held-back click is dropped.
            if Self.exceedsDeadZone(from: pending.anchor, to: point) {
                activate(anchor: pending.anchor, current: point, session: pending.session)
                suppressTriggerUp = true
                return handlePointerMoved(event, isTriggerDrag: isTriggerDrag)
            }

            /// The app hasn't seen the button-down yet, so turn the drag into a plain mouse move.
            ///     (Dropping it would freeze the pointer – events dropped at the HID level don't move the cursor.)
            event.type = .mouseMoved
            return passThrough

        case let .active(anchor, _, session):

            var newSession = session
            if session == .pendingToggleOrHold, isTriggerDrag, Self.exceedsDeadZone(from: anchor, to: point) {
                newSession = .hold
            }
            state = .active(anchor: anchor, current: point, session: newSession)
            indicatorController.update(delta: Self.indicatorDelta(from: anchor, to: point))

            /// The app never saw the button-down, so it shouldn't see a drag either. Turn it into a plain mouse move, so the pointer keeps moving freely, like on Windows.
            ///     (Dropping it would freeze the pointer – events dropped at the HID level don't move the cursor.)
            if isTriggerDrag && suppressTriggerUp {
                event.type = .mouseMoved
                return passThrough
            }

            return passThrough
        }
    }

    // MARK: Accessibility

    private func shouldPreferNativeClick(at point: CGPoint) -> Bool {

        guard config.actAsButtonOverLinks || config.smartAutoScroll else { return false }
        guard AXIsProcessTrusted() else { return false }

        /// Always start Auto Scroll in the Dock (e.g. in a stack). Middle clicks don't do anything there, and stack items count as buttons.
        if let dockPid = Self.dockPid, Self.accessibilityElement(at: point)?.pid == dockPid {
            return false
        }

        /// Use the event location instead of re-sampling the cursor, so the hit-test is anchored to the click we're classifying.
        let hit = accessibilityActivationClassifier.classify(at: point).resolved.hit

        DDLogDebug("AutoScroll: AX hit: \(hit.summary), path: \(hit.path.isEmpty ? "-" : hit.path.joined(separator: " -> "))")

        switch hit {
        case .pressable:
            return config.actAsButtonOverLinks
        case let .nonPressable(diagnostic, path):
            /// If the AX query failed, we don't know whether the area is scrollable. Start Auto Scroll in that case.
            guard config.smartAutoScroll, diagnostic == nil else { return false }
            let isScrollable = path.contains { $0.hasPrefix("AXScrollArea") || $0.hasPrefix("AXWebArea") }
            return !isScrollable
        }
    }

    // MARK: Activation

    private func beginPendingActivation(with event: CGEvent, session: Session) {

        stopReleaseAnimation()

        let point = event.location
        state = .pending(PendingActivation(anchor: point, current: point, bufferedEvents: [event.copy() ?? event], session: session))
        updateTrackingTap()
    }

    private func replayPendingActivation(including finalEvent: CGEvent? = nil) {

        guard case let .pending(pending) = state else { return }

        state = .idle
        let replayedDown = pending.bufferedEvents[0]
        lastReplay = (CACurrentMediaTime(), pending.current, replayedDown.getIntegerValueField(.eventSourceUnixProcessID), replayedDown.timestamp)

        var events = pending.bufferedEvents
        if let finalEvent {
            events.append(finalEvent.copy() ?? finalEvent)
        }
        /// Replay where the pointer is now. The pointer kept moving while we held the click back, and posting at the old location would make it jump back.
        events[0].location = pending.current
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event.post(tap: .cghidEventTap)
        }

        updateTrackingTap()
    }

    private func activate(anchor: CGPoint, current: CGPoint, session: Session) {

        DDLogInfo("AutoScroll: Activated (session: \(session), button: \(config.button))")

        stopReleaseAnimation()
        suppressedExitMouseButton = nil
        state = .active(anchor: anchor, current: current, session: session)
        lastVelocity = .zero
        subPixelRemainder = .zero
        scrollTarget = Self.scrollTarget(at: anchor) /// Before showing the indicator

        indicatorController.show(at: Self.cocoaPoint(anchor))
        indicatorController.update(delta: Self.indicatorDelta(from: anchor, to: current))

        startTimerIfNeeded()
        updateTrackingTap()
    }

    private func deactivate(replayPendingClick: Bool = true) {

        if replayPendingClick {
            replayPendingActivation()
        } else if case .pending = state {
            state = .idle /// Drop the held-back events
        }

        let wasActive = isActive
        state = .idle
        suppressTriggerUp = false

        if wasActive {
            DDLogInfo("AutoScroll: Deactivated")
            indicatorController.hide()
            startReleaseAnimationIfNeeded()
        }

        if releaseAnimation == nil {
            stopTimer()
        }

        updateTrackingTap()
    }

    // MARK: Scrolling

    private func startTimerIfNeeded() {

        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        subPixelRemainder = .zero
        scrollTarget = nil
    }

    // MARK: Scroll target

    private enum ScrollTarget {
        /// Post events straight to the window's process
        case window(number: Int, pid: pid_t, anchor: CGPoint, locationInWindow: CGPoint) /// `anchor`: global CG coordinates, `locationInWindow`: relative to the window's top-left corner
        /// Set the scroll bars of the scroll area at the anchor through Accessibility
        case scrollBars(ScrollBarDriver)
    }

    private static func scrollTarget(at anchor: CGPoint) -> ScrollTarget? {

        let hit = accessibilityElement(at: anchor)

        /// Regular apps: The window that a click at the anchor would hit. (Skips click-through windows like the anchor indicator.)
        let windowNumber = NSWindow.windowNumber(at: cocoaPoint(anchor), belowWindowWithWindowNumber: 0)
        if windowNumber > 0,
           let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[String: Any]])?.first,
           let pid = info[kCGWindowOwnerPID as String] as? pid_t,
           pid != getpid(),
           NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
           hit.map({ $0.pid == pid }) ?? true, /// The window's UI is actually at the anchor
           let boundsDict = info[kCGWindowBounds as String] as! CFDictionary?,
           let bounds = CGRect(dictionaryRepresentation: boundsDict) {
            return .window(number: windowNumber, pid: pid, anchor: anchor, locationInWindow: CGPoint(x: anchor.x - bounds.minX, y: anchor.y - bounds.minY))
        }

        /// Other UI, e.g. Dock stacks: They're drawn by the Dock (an agent app) in an overlay that `windowNumber(at:)` looks through, and the Dock ignores events posted to its process.
        ///     Setting the scroll bars still keeps scrolling the stack when the pointer leaves it.
        if let hit, hit.pid != getpid(), let driver = ScrollBarDriver(scrollAreaAround: hit.element) {
            return .scrollBars(driver)
        }

        return nil /// Post to the event stream, which scrolls the view under the pointer
    }

    /// The UI element at `point` and the process that owns it, according to Accessibility. (One IPC call, bounded by the AX messaging timeout.)
    private static func accessibilityElement(at point: CGPoint) -> (element: AXUIElement, pid: pid_t)? {
        guard AXIsProcessTrusted(),
              case let .success(element?) = AccessibilityElementQuery().systemWideElement(at: point) else {
            return nil
        }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? (element, pid) : nil
    }

    private static var dockPid: pid_t? {
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    /// Private CGEvent field that becomes `NSEvent.windowNumber`
    private static let windowNumberField = CGEventField(rawValue: 51)!

    /// Private CoreGraphics function that sets the window-relative location (top-left origin) which becomes `NSEvent.locationInWindow`
    ///     Looked up at runtime, so we fall back to normal routing if it ever goes away.
    private static let setWindowLocation: (@convention(c) (CGEvent, CGPoint) -> Void)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CGEvent, CGPoint) -> Void).self)
    }()

    private func tick() {

        switch state {
        case let .active(anchor, current, _):

            var velocity = CGVector(dx: scrollAmount(for: anchor.x - current.x),
                                    dy: scrollAmount(for: anchor.y - current.y))
            if config.reverseHorizontal { velocity.dx = -velocity.dx }
            if config.reverseVertical { velocity.dy = -velocity.dy }

            lastVelocity = velocity
            postScroll(velocity)

        case .idle:

            guard let releaseAnimation else {
                stopTimer()
                return
            }

            let progress = (CACurrentMediaTime() - releaseAnimation.startTime) / releaseAnimation.duration
            guard progress < 1 else {
                stopReleaseAnimation()
                return
            }

            let factor = (1 - progress) * (1 - progress) /// Ease out
            postScroll(CGVector(dx: releaseAnimation.velocity.dx * factor, dy: releaseAnimation.velocity.dy * factor))

        case .pending:
            break
        }
    }

    private func scrollAmount(for delta: Double) -> Double {

        /// Pixels per tick for a pointer offset of `delta` from the anchor. Positive delta -> positive scroll.

        let adjusted = abs(delta) - Self.deadZone
        guard adjusted > 0 else { return 0 }

        let speed = config.acceleration / 10
        var value = adjusted * speed * 0.12 + sqrt(adjusted) * speed * 0.6

        /// Super Slowdown: Ramp up linearly inside an extra zone around the dead zone
        if config.superSlowdown > 0 {
            let slowZone = config.superSlowdown * 10
            if adjusted < slowZone {
                value *= adjusted / slowZone
            }
        }

        value = min(Self.maxScrollStep, value)
        return delta < 0 ? -value : value
    }

    private func postScroll(_ velocity: CGVector) {

        /// Carry sub-pixel amounts over to the next tick, so slow scrolling still moves
        subPixelRemainder.dx += velocity.dx
        subPixelRemainder.dy += velocity.dy
        let dx = subPixelRemainder.dx.rounded(.towardZero)
        let dy = subPixelRemainder.dy.rounded(.towardZero)
        subPixelRemainder.dx -= dx
        subPixelRemainder.dy -= dy

        guard dx != 0 || dy != 0 else { return }

        if case let .scrollBars(driver)? = scrollTarget {
            driver.scroll(dx: dx, dy: dy)
            return
        }

        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            return
        }
        event.flags = [] /// Held modifiers shouldn't turn this into zooming or horizontal scrolling
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        
        if case let .window(windowNumber, pid, anchor, locationInWindow)? = scrollTarget, let setWindowLocation = Self.setWindowLocation {
            /// Send the event straight to the window where Auto Scroll started, so it keeps scrolling when the pointer moves over another window, like on Windows.
            ///     AppKit routes events posted to a process by their window number and window location, not by the cursor position.
            ///     Note: Posting into the event stream with `event.location` set instead would move the cursor there (-> the pointer would be stuck at the anchor).
            event.location = anchor
            event.setIntegerValueField(Self.windowNumberField, value: Int64(windowNumber))
            setWindowLocation(event, locationInWindow)
            event.postToPid(pid)
        } else {
            event.post(tap: .cgSessionEventTap) /// Goes to the view under the pointer
        }
    }

    private func startReleaseAnimationIfNeeded() {

        guard config.animateRelease,
              config.releaseDuration > 0,
              lastVelocity.dx != 0 || lastVelocity.dy != 0 else {
            return
        }

        releaseAnimation = ReleaseAnimation(velocity: lastVelocity, startTime: CACurrentMediaTime(), duration: config.releaseDuration / 1000)
    }

    private func stopReleaseAnimation() {
        releaseAnimation = nil
        if !isActive {
            stopTimer()
        }
    }

    // MARK: Helpers

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    private var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private static func isMouseDown(_ type: CGEventType) -> Bool {
        return type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }

    private static func isMouseUp(_ type: CGEventType) -> Bool {
        return type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
    }

    private static func isOtherMouseEvent(_ type: CGEventType) -> Bool {
        return type == .otherMouseDown || type == .otherMouseUp || type == .otherMouseDragged
    }

    private static func exceedsDeadZone(from anchor: CGPoint, to point: CGPoint) -> Bool {
        return abs(point.x - anchor.x) > deadZone || abs(point.y - anchor.y) > deadZone
    }

    private static func indicatorDelta(from anchor: CGPoint, to point: CGPoint) -> CGVector {
        /// The indicator uses Cocoa coordinates (y points up)
        return CGVector(dx: point.x - anchor.x, dy: anchor.y - point.y)
    }

    private static func cocoaPoint(_ point: CGPoint) -> CGPoint {
        /// Convert from global CG coordinates (origin top-left of the primary screen) to Cocoa coordinates (origin bottom-left of the primary screen)
        return SharedUtility.quartz(toCocoaScreenSpace_Point: point)
    }
}

// MARK: - Scroll bar driver

/// Scrolls a scroll area by setting its scroll bars' values through Accessibility.
///     For UI that ignores events posted to its process, like Dock stacks. One AX call per tick (~0.4 ms for a Dock stack).
private final class ScrollBarDriver {

    private struct ScrollBar {
        let element: AXUIElement
        let scrollableLength: Double /// Content length minus visible length in px, derived from the thumb size
        var value: Double            /// 0...1. Tracked here, so pixel steps add up exactly even if the app rounds the value it reports.
    }

    private var vertical: ScrollBar?
    private var horizontal: ScrollBar?
    private var isValid = true

    private static let query = AccessibilityElementQuery()

    init?(scrollAreaAround element: AXUIElement) {

        /// Find the enclosing scroll area
        var scrollArea: AXUIElement?
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let candidate = current else { break }
            if Self.get(Self.query.optionalStringValue(of: kAXRoleAttribute as CFString, on: candidate)) == kAXScrollAreaRole {
                scrollArea = candidate
                break
            }
            current = Self.get(Self.query.optionalElementValue(of: kAXParentAttribute as CFString, on: candidate))
        }
        guard let scrollArea, let visible = Self.get(Self.query.optionalFrameValue(of: scrollArea)) else { return nil }

        /// Look at the children, because not all scroll areas have the vertical / horizontal scroll bar attributes (Dock stacks don't)
        for child in Self.get(Self.query.optionalElementArrayValue(of: kAXChildrenAttribute as CFString, on: scrollArea)) ?? []
        where Self.get(Self.query.optionalStringValue(of: kAXRoleAttribute as CFString, on: child)) == kAXScrollBarRole {
            switch Self.get(Self.query.optionalStringValue(of: kAXOrientationAttribute as CFString, on: child)) {
            case kAXVerticalOrientationValue:   vertical = Self.scrollBar(child, visibleLength: visible.height, isVertical: true)
            case kAXHorizontalOrientationValue: horizontal = Self.scrollBar(child, visibleLength: visible.width, isVertical: false)
            default: break
            }
        }
        guard vertical != nil || horizontal != nil else { return nil }
    }

    /// Scrolls by `dx` / `dy` px. Same sign convention as scroll wheel events: positive = towards the top / left.
    func scroll(dx: Double, dy: Double) {
        if dy != 0 { vertical = step(vertical, by: -dy) }
        if dx != 0 { horizontal = step(horizontal, by: -dx) }
    }

    private func step(_ scrollBar: ScrollBar?, by pixels: Double) -> ScrollBar? {
        guard isValid, var scrollBar else { return scrollBar }
        let value = min(1, max(0, scrollBar.value + pixels / scrollBar.scrollableLength))
        guard value != scrollBar.value else { return scrollBar } /// Already at the end
        scrollBar.value = value
        if AXUIElementSetAttributeValue(scrollBar.element, kAXValueAttribute as CFString, NSNumber(value: value)) == .invalidUIElement {
            isValid = false /// E.g. the stack was closed
        }
        return scrollBar
    }

    private static func scrollBar(_ element: AXUIElement, visibleLength: Double, isVertical: Bool) -> ScrollBar? {
        var isSettable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isSettable) == .success, isSettable.boolValue,
              let value = (get(query.optionalAttributeValue(of: kAXValueAttribute as CFString, on: element)) as? NSNumber)?.doubleValue,
              let track = get(query.optionalFrameValue(of: element)),
              let thumbElement = (get(query.optionalElementArrayValue(of: kAXChildrenAttribute as CFString, on: element)) ?? []).first(where: {
                  get(query.optionalStringValue(of: kAXRoleAttribute as CFString, on: $0)) == kAXValueIndicatorRole
              }),
              let thumb = get(query.optionalFrameValue(of: thumbElement)) else {
            return nil
        }
        let thumbRatio = isVertical ? thumb.height / track.height : thumb.width / track.width
        guard thumbRatio > 0, thumbRatio < 1 else { return nil } /// Nothing to scroll
        return ScrollBar(element: element, scrollableLength: visibleLength * (1 / thumbRatio - 1), value: value)
    }

    private static func get<Value>(_ result: AccessibilityQueryResult<Value?>) -> Value? {
        if case let .success(value) = result { return value }
        return nil
    }
}
