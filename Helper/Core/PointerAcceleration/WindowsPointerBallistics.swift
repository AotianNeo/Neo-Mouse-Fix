//
// --------------------------------------------------------------------------
// WindowsPointerBallistics.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// The pointer acceleration curve of Windows 10 and 11 ('Enhance pointer precision'), as an acceleration table for macOS' HID driver.
///
/// **Windows** – reconstructed from measurements on Windows 11 (build 28000): Relative `SendInput` moves of known size, cursor movement read back in a DPI-aware process, default curve read from the registry. Per mouse report:
/// 1. Magnitude: `max(|dx|, |dy|) + min(|dx|, |dy|) / 2` counts.
/// 2. Look up `magnitude / 3.5` on the piecewise linear curve made of `SmoothMouseXCurve` / `SmoothMouseYCurve` (last segment extrapolated).
/// 3. Quirk: If the magnitude lands in a higher curve segment than the previous report's, Windows averages the previous and the current segment's line.
/// 4. Pixels = curve value × DPI / 120 × pointer speed / 10, split onto the axes in proportion to dx and dy.
///     (We work in points, which correspond to Windows pixels at 100 % scaling / 96 DPI.)
///
/// **macOS** – `IOHIDPointerScrollFilter` (in hidd) accelerates every mouse report anyway. Usually with parametric curves, but it can be switched to an acceleration table (`HIDPointerAccelerationAlgorithm` = Table). Then, per report (see `IOHIDPointerAccelerator::accelerate` and `IOHIDTableAcceleration` in Apple's IOHIDFamily source):
/// - velocity = `floor(√(dx² + dy²))` × `HIDPointerAccelerationMultiplier`. (With a multiplier of 1, a report-rate factor is used instead, which slows down reports that arrive late. Any other multiplier turns that off.)
/// - The table is a list of points, joined into line segments (last one extrapolated). Table x is scaled by `resolution / 67`, table y by `96 / 67`. Output = f(velocity), applied to dx and dy in proportion.
/// So we give it Windows' curve as a table. That costs nothing extra – the driver does this work for every report anyway.
///
/// Differences to Windows (computed for all reports up to ±40 counts):
/// - Straight horizontal / vertical moves: identical.
/// - Diagonal moves: macOS measures the Euclidean length (rounded down) instead of Windows' approximation, so they come out 1.5–4.5 % slower on average, up to 16 % for single reports.
/// - No segment-crossing quirk (step 3). It only shortens the first report after speeding up.

import Foundation

enum WindowsPointerBallistics {

    /// Default `SmoothMouseXCurve` / `SmoothMouseYCurve` of Windows 8 and later (`HKCU\Control Panel\Mouse`), 16.16 fixed point
    static let curveX: [Double] = [0x0, 0x6E15, 0x14000, 0x3DC29, 0x280000].map { $0 / 65536 }
    static let curveY: [Double] = [0x0, 0x111FD, 0x42400, 0x12FC00, 0x1BBC000].map { $0 / 65536 }

    /// Value for `HIDPointerAccelerationMultiplier`. Not 1, so the driver doesn't scale velocity by report timing (Windows doesn't either). The table compensates for it.
    static let velocityMultiplier = 2.0

    /// macOS' built-in acceleration table (`defaultAccelTable` in Apple's IOHIDPointerScrollFilter.cpp). The pointer filter uses it when a device has no table of its own.
    ///     Many mice don't have parametric curves, so macOS accelerates them with this table – also in the normal (Default) algorithm mode. That's why switching the algorithm back isn't enough to undo our table: we have to put this one back.
    static let appleDefaultTable = Data([
        0x00, 0x00, 0x80, 0x00, 0x40, 0x32, 0x30, 0x30, 0x00, 0x02, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x71, 0x3B, 0x00, 0x00,
        0x60, 0x00, 0x00, 0x04, 0x4E, 0xC5, 0x00, 0x10, 0x80, 0x00, 0x00, 0x0C,
        0x00, 0x00, 0x00, 0x5F, 0x00, 0x00, 0x00, 0x16, 0xEC, 0x4F, 0x00, 0x8B,
        0x00, 0x00, 0x00, 0x1D, 0x3B, 0x14, 0x00, 0x94, 0x80, 0x00, 0x00, 0x22,
        0x76, 0x27, 0x00, 0x96, 0x00, 0x00, 0x00, 0x24, 0x62, 0x76, 0x00, 0x96,
        0x00, 0x00, 0x00, 0x26, 0x00, 0x00, 0x00, 0x96, 0x00, 0x00, 0x00, 0x28,
        0x00, 0x00, 0x00, 0x96, 0x00, 0x00,
    ])

    /// Windows' pointer movement in points for a straight move of `counts` in one report, at pointer speed `speed` (1...20, 10 = middle). (Without the quirk.)
    static func windowsMovement(counts: Double, speed: Double) -> Double {
        let x = counts / 3.5
        var segment = curveX.count - 1
        for i in 1..<curveX.count where x <= curveX[i] {
            segment = i
            break
        }
        let (x0, x1, y0, y1) = (curveX[segment - 1], curveX[segment], curveY[segment - 1], curveY[segment])
        return (y0 + (y1 - y0) / (x1 - x0) * (x - x0)) * (96.0 / 120.0) * (speed / 10)
    }

    /// Goes into the table's unused 'scale' field, so we can recognize our tables. (A table of ours is never a device's original table.)
    private static let marker: [UInt8] = Array("MMFW".utf8)

    static func isOurTable(_ table: CFTypeRef?) -> Bool {
        guard let data = table as? Data, data.count >= 4 else { return false }
        return Array(data.prefix(4)) == marker
    }

    /// Acceleration table (`HIDPointerAccelerationTable`) with Windows' curve
    /// - Parameters:
    ///   - speed: Windows' pointer speed, 1...20
    ///   - resolution: The device's `HIDPointerResolution` in dpi (the driver scales the table by it)
    static func accelerationTable(speed: Double, resolution: Double) -> Data {

        /// Format (see `IOHIDAccelerationTable.hpp`): All numbers big-endian, values 16.16 fixed point.
        ///     Header: scale (the table algorithm doesn't use it – we put a marker there), signature, number of curves. Then per curve: acceleration level, number of points, points (x, y).
        ///     The origin is implied. Curves for different acceleration levels get interpolated – we give the same curve for the lowest and highest level, so the Tracking speed set in System Settings doesn't matter.
        func fixed(_ value: Double) -> [UInt8] {
            let bits = UInt32(bitPattern: Int32((value * 65536).rounded()))
            return [UInt8(bits >> 24), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
        }
        var points: [UInt8] = []
        for i in 1..<curveX.count {
            let counts = 3.5 * curveX[i]
            let movement = windowsMovement(counts: counts, speed: speed)
            points += fixed(counts * velocityMultiplier * 67 / resolution) + fixed(movement * velocityMultiplier * 67 / 96) /// y too: the driver divides f(velocity) by the multiplied velocity
        }
        let pointCount = [UInt8(0), UInt8(curveX.count - 1)]

        var table = marker + [0x40, 0x32, 0x30, 0x30] + [0, 2] /// Signature: APPLE_ACCELERATION_DEFAULT_TABLE_SIGNATURE in memory order
        for level in [0.0, 32767.0] {
            table += fixed(level) + pointCount + points
        }
        return Data(table)
    }
}
