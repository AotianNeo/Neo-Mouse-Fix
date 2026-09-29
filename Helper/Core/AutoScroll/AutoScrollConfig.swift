//
// --------------------------------------------------------------------------
// AutoScrollConfig.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// Typed view of the `AutoScroll` dict in config.plist. Edited on the 'Auto Scroll' tab (`AutoScrollTabController`).
///
/// Every key falls back to the value below if it's missing, because `Config.m` doesn't merge new keys from `default_config.plist` into an existing config.plist unless the `configVersion` changes.
/// Keep these fallbacks in sync with the `AutoScroll` dict in `default_config.plist`.
///
/// Keys:
/// - `enabled`               Master switch
/// - `button`                Trigger button, using MMF's 1-based numbering (3 = middle button). Buttons 1 and 2 aren't allowed.
/// - `actAsButtonOverLinks`  Clicking over a link / button / tab performs the normal click instead of starting Auto Scroll. (Dragging still starts Auto Scroll.)
/// - `holdToActivate`        Press, drag, and release to Auto Scroll. Releasing the button stops scrolling.
/// - `clickToToggle`         Click once to start Auto Scroll, click again (or click any button, or use the wheel) to stop. Combined with `holdToActivate`, this is the Windows behavior.
/// - `smartAutoScroll`       Clicking outside of a scrollable area performs the normal click instead of starting Auto Scroll. (Dragging still starts Auto Scroll.)
/// - `acceleration`          1...20. How quickly scrolling speeds up as you move away from the anchor point. 10 is LinearMouse's default speed.
/// - `superSlowdown`         0...20. Size of an extra slow zone around the dead zone for precise, slow scrolling (× 10 px). 0 turns it off.
/// - `animateRelease`        Keep gliding and slow down when Auto Scroll stops, instead of stopping instantly.
/// - `releaseDuration`       0...3000. Length of the release animation in milliseconds.
/// - `reverseVertical`       Flip the vertical scroll direction.
/// - `reverseHorizontal`     Flip the horizontal scroll direction.

import Cocoa

struct AutoScrollConfig: Equatable {

    var enabled = false /// Off by default, so updating MMF doesn't change how the middle button behaves
    var button = 3
    var actAsButtonOverLinks = true
    var holdToActivate = true
    var clickToToggle = true
    var smartAutoScroll = false
    var acceleration = 10.0
    var superSlowdown = 0.0
    var animateRelease = false
    var releaseDuration = 400.0
    var reverseVertical = false
    var reverseHorizontal = false

    /// Derived

    var isUsable: Bool {
        return enabled && (holdToActivate || clickToToggle)
    }
    var cgButtonNumber: Int64 {
        return Int64(button - 1) /// CGEvents use 0-based button numbers
    }

    /// Load

    static func load() -> AutoScrollConfig {

        var result = AutoScrollConfig()
        guard let dict = config("AutoScroll") as? NSDictionary else {
            return result
        }

        func bool(_ key: String, _ fallback: Bool) -> Bool {
            return (dict[key] as? NSNumber)?.boolValue ?? fallback
        }
        func double(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let value = (dict[key] as? NSNumber)?.doubleValue ?? fallback
            return min(max(value, range.lowerBound), range.upperBound)
        }

        result.enabled              = bool("enabled", result.enabled)
        result.button               = Int(double("button", Double(result.button), 3...32))
        result.actAsButtonOverLinks = bool("actAsButtonOverLinks", result.actAsButtonOverLinks)
        result.holdToActivate       = bool("holdToActivate", result.holdToActivate)
        result.clickToToggle        = bool("clickToToggle", result.clickToToggle)
        result.smartAutoScroll      = bool("smartAutoScroll", result.smartAutoScroll)
        result.acceleration         = double("acceleration", result.acceleration, 1...20)
        result.superSlowdown        = double("superSlowdown", result.superSlowdown, 0...20)
        result.animateRelease       = bool("animateRelease", result.animateRelease)
        result.releaseDuration      = double("releaseDuration", result.releaseDuration, 0...3000)
        result.reverseVertical      = bool("reverseVertical", result.reverseVertical)
        result.reverseHorizontal    = bool("reverseHorizontal", result.reverseHorizontal)

        return result
    }
}
