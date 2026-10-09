//
// --------------------------------------------------------------------------
// AdaptiveScrollSpeed.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// Scrolls farther over icon grids (Finder icon view, Dock stacks), so a scroll wheel tick moves about as many rows there as elsewhere.
///
/// Background (measured in Finder and the Dock, with Windows-style scrolling at medium speed):
/// - MMF sends each tick (with smooth scrolling off) as a classic scroll wheel event: 30 pt = 3 lines.
/// - Tables and outlines (e.g. Finder list view) scroll by their row height per line, so they already adapt: 56 pt per tick (~3 rows of 20 pt). We leave them alone – multiplying would double up.
/// - Icon grids don't: Finder's icon view scrolls 10 pt per line (28 pt per tick), and the Dock uses the point delta (30 pt per tick). With rows of ~100–128 pt that's a quarter row per tick.
/// So over icon grids we multiply by row pitch / 20 pt (a list row). E.g. Finder icon view: ~5x -> 154 pt, Dock stack (128 pt rows): 6.4x -> 192 pt (~1.5 rows each).
///
/// Detection: At the start of each scroll, ask the app under the pointer (through Accessibility) what's there, and look for an icon grid above it: `AXGrid`, or an `AXList` with several items per row.
///     Dock stacks are checked first: The window lookup (`appUnderMousePointerWithEvent:`) looks through the Dock's stack overlay at the window behind it.
///
/// Performance:
/// - Once per scroll (not per tick), on the scroll queue. Typically < 1 ms.
/// - Only the app under the pointer is asked, with a short timeout. Apps that time out 3 times in a row are skipped for a minute.
/// - Browsers and Electron apps are skipped: Accessibility queries can switch them into a slower accessibility mode, and web content has no icon grids anyway.
///
/// Used by scroll wheel scrolling (`Scroll.m`, at the start of each scroll) and by Auto Scroll (`AutoScroll.swift`, when it starts).
///     Thread safe: Calls are serialized with a lock (they come from the scroll queue and from Auto Scroll's queue).

import Cocoa

@objc class AdaptiveScrollSpeed: NSObject {

    private static let referenceRowHeight = 20.0 /// A list row (Finder list view)
    private static let maxMultiplier = 8.0
    private static let timeout: Float = 0.02
    private static let slowAppPenalty: TimeInterval = 60
    private static var dock: (pid: pid_t, element: AXUIElement)?
    private static var skippedApps: [pid_t: Bool] = [:]       /// Browsers / Electron apps
    private static var timeouts: [pid_t: (count: Int, last: CFTimeInterval)] = [:] /// Consecutive timeouts per app. The first query to an app is often slow (50–85 ms measured for Finder), so we only skip apps that time out repeatedly.

    private static let lock = NSLock()

    /// Multiplier for the scroll distance at `location` (global CG coordinates)
    @objc static func multiplier(at location: CGPoint) -> Double {

        lock.lock()
        defer { lock.unlock() }

        guard AXIsProcessTrusted() else { return 1 }

        /// Dock stacks
        if let dock = dockElement(), let hit = elementAt(location, in: dock, pid: nil) {
            return gridRowPitch(around: hit, pid: nil).map(multiplier) ?? 1 /// Only stacks are grids. (The Dock itself is a single-row list.)
        }

        /// The app under the pointer
        guard let app = HelperUtility.appUnderMousePointer(with: nil), app.bundleIdentifier != "com.apple.dock", !isSkipped(app) else { return 1 }
        let pid = app.processIdentifier
        if let t = timeouts[pid], t.count >= 3, CACurrentMediaTime() - t.last < slowAppPenalty { return 1 }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        guard let hit = elementAt(location, in: appElement, pid: pid) else { return 1 }
        timeouts[pid] = nil /// It answered
        return gridRowPitch(around: hit, pid: pid).map(multiplier) ?? 1
    }

    private static func multiplier(_ pitch: Double) -> Double {
        return min(max(pitch / referenceRowHeight, 1), maxMultiplier)
    }

    // MARK: Rows

    /// Row pitch of the icon grid that contains `element`. Nil if it's not in one – e.g. text, or a table / outline, which already scrolls by rows.
    private static func gridRowPitch(around element: AXUIElement, pid: pid_t?) -> Double? {
        var current: AXUIElement? = element
        for _ in 0..<6 { /// E.g. Finder icon view: AXGroup (item / section) > AXList > AXList > AXScrollArea. Dock stack: AXImage > AXGrid > AXScrollArea.
            guard let candidate = current, let role = value(candidate, kAXRoleAttribute, pid: pid) as? String else { return nil }
            switch role {
            case kAXGridRole, kAXListRole:
                return itemPitch(in: candidate, pid: pid)
            case kAXRowRole, kAXOutlineRole, kAXTableRole, kAXScrollAreaRole, kAXWindowRole, kAXApplicationRole, "AXWebArea":
                return nil
            default:
                current = value(candidate, kAXParentAttribute, pid: pid).map { $0 as! AXUIElement }
            }
        }
        return nil
    }

    /// Distance between rows of items. Nil unless there are several items in a row – a list with one item per row isn't a grid.
    private static func itemPitch(in grid: AXUIElement, pid: pid_t?) -> Double? {

        /// The first few items. (Only fetch a range – a folder's icon view can have thousands of children.)
        var items = values(grid, kAXVisibleChildrenAttribute, count: 24, pid: pid)
        if items.isEmpty {
            items = values(grid, kAXChildrenAttribute, count: 24, pid: pid)
        }
        guard let gridFrame = frame(grid, pid: pid) else { return nil }

        /// Skip a leading section group that spans the whole grid (Finder's icon view has one)
        if let first = items.first, let f = frame(first, pid: pid), f.height >= gridFrame.height / 2 {
            items.removeFirst()
        }
        guard items.count >= 2, let first = frame(items[0], pid: pid), let second = frame(items[1], pid: pid) else { return nil }
        func sameRow(_ index: Int) -> Bool? {
            return frame(items[index], pid: pid).map { abs($0.minY - first.minY) < 2 }
        }
        guard abs(second.minY - first.minY) < 2 else { return nil } /// One item per row: not a grid

        /// Items are listed row by row. Find the first item of the second row: double the index until we leave the first row, then bisect.
        ///     Each frame is an Accessibility message (~0.2 ms), so we read as few as possible.
        var inRow = 1, outOfRow: Int?
        var index = 2
        while index < items.count {
            guard let same = sameRow(index) else { return nil }
            if !same { outOfRow = index; break }
            inRow = index
            index *= 2
        }
        if outOfRow == nil, inRow < items.count - 1 {
            guard let same = sameRow(items.count - 1) else { return nil }
            if !same { outOfRow = items.count - 1 }
        }
        guard var high = outOfRow else { return Double(first.height) } /// A single row: use the item height
        var low = inRow
        while high - low > 1 {
            let middle = (low + high) / 2
            guard let same = sameRow(middle) else { return nil }
            if same { low = middle } else { high = middle }
        }
        guard let nextRow = frame(items[high], pid: pid) else { return nil }
        let pitch = Double(nextRow.minY - first.minY)
        return pitch > 0 && pitch < Double(gridFrame.height) / 2 ? pitch : nil
    }

    // MARK: Dock

    private static func dockElement() -> AXUIElement? {
        if let dock, NSRunningApplication(processIdentifier: dock.pid) != nil {
            return dock.element
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, timeout)
        dock = (app.processIdentifier, element)
        return element
    }

    // MARK: Apps

    private static func isSkipped(_ app: NSRunningApplication) -> Bool {
        if let cached = skippedApps[app.processIdentifier] {
            return cached
        }
        let browsers = ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS"]
        var result = browsers.contains { app.bundleIdentifier?.hasPrefix($0) ?? false }
        if !result, let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks") {
            result = ["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains { FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path) }
        }
        skippedApps[app.processIdentifier] = result
        return result
    }

    // MARK: Accessibility

    /// `pid`: The app to mark as slow if it times out. (Nil for the Dock.)
    private static func elementAt(_ location: CGPoint, in root: AXUIElement, pid: pid_t?) -> AXUIElement? {
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(root, Float(location.x), Float(location.y), &element)
        noteTimeout(error, pid: pid)
        return error == .success ? element : nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String, pid: pid_t?) -> AnyObject? {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
        noteTimeout(error, pid: pid)
        return error == .success ? result : nil
    }

    private static func values(_ element: AXUIElement, _ attribute: String, count: Int, pid: pid_t?) -> [AXUIElement] {
        var result: CFArray?
        let error = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, count, &result)
        noteTimeout(error, pid: pid)
        return error == .success ? (result as? [AXUIElement]) ?? [] : []
    }

    private static func noteTimeout(_ error: AXError, pid: pid_t?) {
        if error == .cannotComplete, let pid {
            timeouts[pid] = ((timeouts[pid]?.count ?? 0) + 1, CACurrentMediaTime())
        }
    }

    private static func frame(_ element: AXUIElement, pid: pid_t?) -> CGRect? {
        /// Position and size in one message
        var result: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, [kAXPositionAttribute, kAXSizeAttribute] as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result)
        noteTimeout(error, pid: pid)
        guard error == .success, let pair = result as? [AnyObject], pair.count == 2,
              CFGetTypeID(pair[0]) == AXValueGetTypeID(), CFGetTypeID(pair[1]) == AXValueGetTypeID() else { return nil }
        let position = pair[0], size = pair[1]
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
