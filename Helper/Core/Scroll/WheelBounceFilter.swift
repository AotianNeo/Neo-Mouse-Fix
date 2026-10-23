//
// --------------------------------------------------------------------------
// WheelBounceFilter.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// Ignores the stray ticks in the wrong direction that worn scroll wheels send (`Scroll.wheelBounceFilter`).
///
/// Background:
/// - The scroll wheel's encoder is a pair of mechanical contacts. When they wear out or get dirty, they bounce, and the mouse's count wobbles
///     around the point where it sends the next tick. You get a tick in the wrong direction – the page jumps back while you scroll – and then a tick that undoes it.
///     A wheel resting at that point flickers back and forth when the mouse moves. And a wheel that's spun fast can bounce back a notch when it stops.
/// - So stray ticks come alone, and usually right before or after another tick. A real change of direction comes after a pause, or as several ticks in a row.
///
/// Rules (per axis). 'Forward' = the direction of the last tick we sent:
/// - Forward ticks go through right away.
/// - A backward tick is held back:
///     - Another backward tick follows -> the user changed direction: Both go through.
///     - A forward tick follows -> a stray tick and the tick that undoes it: Both are dropped.
///     - Nothing follows: If it came within `pauseTime` of the last tick, it's dropped (e.g. the wheel bouncing back when it stops).
///         After a pause, it goes through after `holdTime` (the user changed direction, with a single notch).
/// So a change of direction right after scrolling needs two notches, and after a pause the first notch arrives `holdTime` late.
///
/// Thread safety: Call on the scroll queue only. `send` and `discard` are called on the scroll queue.

import Cocoa

@objc class WheelBounceFilter: NSObject {

    static let pauseTime: CFTimeInterval = 0.25 /// A lone backward tick within this time of the last tick is a stray tick
    static let holdTime: CFTimeInterval = 0.05  /// A backward tick after a pause waits this long for a forward tick that undoes it. (Stray ticks are undone within a few ms.)

    @objc static var queue: DispatchQueue! /// The scroll queue. Set by Scroll.m
    static var schedule: (_ delay: CFTimeInterval, _ block: @escaping () -> Void) -> Void = { delay, block in
        queue.asyncAfter(deadline: .now() + delay, execute: block)
    }

    private struct Tick {
        let id: Int
        let direction: Int
        let time: CFTimeInterval
        let gap: CFTimeInterval /// Since the previous tick
        var afterPause: Bool { gap > pauseTime }
        let send: () -> Void
        let discard: () -> Void
    }
    private struct AxisState {
        var direction = 0                       /// Of the last tick we sent. 0 = none yet
        var lastTime = -CFTimeInterval.infinity /// Of the last tick that came in
        var held: Tick? = nil                   /// Backward tick
    }
    private static var axes = [AxisState(), AxisState()] /// Vertical, horizontal
    private static var lastID = 0

    /// Call for every scroll wheel tick. Calls either `send` or `discard` exactly once – right away or later.
    @objc static func filterTick(deltaAxis1: Int64, deltaAxis2: Int64, time: CFTimeInterval, send: @escaping () -> Void, discard: @escaping () -> Void) {

        let axis = deltaAxis1 != 0 ? 0 : 1
        let direction = Int((deltaAxis1 != 0 ? deltaAxis1 : deltaAxis2).signum())
        guard direction != 0 else { send(); return }

        /// A backward tick is held
        if let held = axes[axis].held {
            if time - held.time > (held.afterPause ? holdTime : pauseTime) {
                release(axis) /// Its timer hasn't fired yet
            } else {
                axes[axis].held = nil
                axes[axis].lastTime = time
                if direction == held.direction {
                    axes[axis].direction = direction
                    held.send()
                    send()
                } else {
                    DDLogInfo("WheelBounceFilter: Dropped a tick in the wrong direction and the tick that undid it \(ms(time - held.time)) later")
                    held.discard()
                    discard()
                }
                return
            }
        }

        let gap = time - axes[axis].lastTime
        axes[axis].lastTime = time

        if axes[axis].direction == 0 || direction == axes[axis].direction {
            /// Forward
            axes[axis].direction = direction
            send()
        } else {
            /// Backward -> hold it
            lastID += 1
            let tick = Tick(id: lastID, direction: direction, time: time, gap: gap, send: send, discard: discard)
            axes[axis].held = tick
            schedule(tick.afterPause ? holdTime : pauseTime) {
                if axes[axis].held?.id == tick.id { release(axis) }
            }
        }
    }

    /// Nothing followed the held tick
    private static func release(_ axis: Int) {
        guard let held = axes[axis].held else { return }
        axes[axis].held = nil
        if held.afterPause {
            axes[axis].direction = held.direction
            held.send()
        } else {
            DDLogInfo("WheelBounceFilter: Dropped a lone tick in the wrong direction \(ms(held.gap)) after the previous tick")
            held.discard()
        }
    }

    private static func ms(_ t: CFTimeInterval) -> String {
        return String(format: "%.0f ms", t * 1000)
    }
}
