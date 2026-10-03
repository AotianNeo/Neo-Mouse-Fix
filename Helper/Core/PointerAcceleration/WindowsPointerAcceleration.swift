//
// --------------------------------------------------------------------------
// WindowsPointerAcceleration.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// Gives mice that MMF manages the pointer acceleration of Windows 10 / 11 ('Enhance pointer precision'). Not the trackpad.
///
/// How it works:
/// - macOS' HID driver accelerates every mouse report in `IOHIDPointerScrollFilter` (in hidd). We switch it to an acceleration table with Windows' curve (see `WindowsPointerBallistics`), by setting properties on each mouse's HID service:
///     `HIDPointerAccelerationTable` (the table, on the driver's registry entry), `HIDPointerAccelerationMultiplier` (no report-timing factor), and then `HIDPointerAccelerationAlgorithm` = Table, which makes the filter rebuild its accelerator.
///     Check what the filter built with `hidutil dump services` (`ServiceFilterDebug` > IOHIDPointerScrollFilter > Pointer Accelerator).
/// - No event tap, nothing runs per event.
/// - The settings belong to the device's HID service, so they last until the device disconnects or we restore them. We restore them when the feature is turned off, when the Helper quits, and when another user becomes active (the HID services are shared by all users).
///     If the Helper is killed without a chance to clean up, the mouse keeps the Windows curve until it's reconnected.
///
/// Config: `Pointer.windowsAcceleration` (Bool) and `Pointer.windowsSpeed` (1...20, Windows' 'Pointer speed' slider). Edited on the 'Pointer' tab (`WindowsPointerTabController`).

import Cocoa
import IOKit.hid

struct WindowsPointerConfig: Equatable {

    /// Fallbacks for missing keys, because `Config.m` doesn't merge new keys from `default_config.plist` into an existing config.plist unless the `configVersion` changes.
    ///     Keep in sync with the `Pointer` dict in `default_config.plist`.
    var enabled = false /// Off by default, so updating MMF doesn't change how the pointer moves
    var speed = 10.0

    static func load() -> WindowsPointerConfig {
        var result = WindowsPointerConfig()
        guard let dict = config("Pointer") as? NSDictionary else { return result }
        result.enabled = (dict["windowsAcceleration"] as? NSNumber)?.boolValue ?? result.enabled
        result.speed = min(max((dict["windowsSpeed"] as? NSNumber)?.doubleValue ?? result.speed, 1), 20)
        return result
    }
}

/// Private. A passive client can read and set properties of the HID services. (The public 'simple' client doesn't list pointing devices.) Also see `PointerSpeed.m`.
@_silgen_name("IOHIDEventSystemClientCreateWithType")
private func IOHIDEventSystemClientCreateWithType(_ allocator: CFAllocator?, _ type: Int32, _ attributes: CFDictionary?) -> IOHIDEventSystemClient?

@objc class WindowsPointerAcceleration: NSObject {

    @objc static let shared = WindowsPointerAcceleration()

    private enum Key {
        static let table = "HIDPointerAccelerationTable"           /// kIOHIDPointerAccelerationTableKey
        static let algorithm = "HIDPointerAccelerationAlgorithm"   /// kIOHIDPointerAccelerationAlgorithmKey
        static let multiplier = "HIDPointerAccelerationMultiplier" /// kIOHIDPointerAccelerationMultiplierKey
        static let linearScaling = "HIDUseLinearScalingMouseAcceleration" /// The 'Pointer acceleration' switch in System Settings. When on, the driver doesn't use the table.
        static let accelerationType = "HIDPointerAccelerationType"
        static let resolution = "HIDPointerResolution"
    }
    private enum Algorithm {
        static let table = 0   /// kIOHIDAccelerationAlgorithmTypeTable
        static let normal = 2  /// kIOHIDAccelerationAlgorithmTypeDefault: The driver's parametric curves, like before
    }

    /// Values we changed on a service, to restore them
    private struct Original {
        let service: IOHIDServiceClient
        let table: CFTypeRef?                  /// Nil if the device had no table of its own
        let multiplier: CFTypeRef?
        let linearScaling: CFTypeRef?          /// Only set if we changed it
        let accelerationKey: String
        let acceleration: CFTypeRef?           /// Only set if we changed it
    }

    private let lock = NSLock() /// Called on the main thread, and from the termination handler
    private var config = WindowsPointerConfig()
    private var allowedBySwitchMaster = false
    private var configured: [UInt64: Original] = [:] /// By service registry ID
    private lazy var client = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 2 /* passive */, nil) /// Kept for the Helper's lifetime. Its service objects become invalid when it's released.

    // MARK: Interface

    @objc static func reload() {
        /// Called by `Config` whenever the config changes
        let newConfig = WindowsPointerConfig.load()
        shared.locked {
            guard newConfig != shared.config else { return }
            DDLogInfo("WindowsPointerAcceleration: Config changed: \(newConfig)")
            shared.config = newConfig
            shared.update()
        }
    }

    @objc func setAllowedBySwitchMaster(_ allowed: Bool) {
        locked {
            guard allowed != allowedBySwitchMaster else { return }
            allowedBySwitchMaster = allowed
            update()
        }
    }

    @objc func attachedDevicesChanged() {
        locked { update() }
    }

    @objc func restoreAllDevices() {
        /// Called when the Helper terminates
        locked { restoreAll() }
    }

    // MARK: Applying

    private func update() {

        guard config.enabled && allowedBySwitchMaster else {
            restoreAll()
            return
        }

        let services = mouseServices()
        configured = configured.filter { services[$0.key] != nil } /// Disconnected devices take their settings with them
        for (id, service) in services {
            apply(to: service, id: id)
        }
    }

    private func apply(to service: IOHIDServiceClient, id: UInt64) {

        let accelerationKey = (IOHIDServiceClientCopyProperty(service, Key.accelerationType as CFString) as? String) ?? kIOHIDMouseAccelerationType
        if configured[id] == nil {
            let linearScaling = IOHIDServiceClientCopyProperty(service, Key.linearScaling as CFString)
            let acceleration = IOHIDServiceClientCopyProperty(service, accelerationKey as CFString)
            configured[id] = Original(service: service,
                                      table: Self.originalTable(of: service),
                                      multiplier: IOHIDServiceClientCopyProperty(service, Key.multiplier as CFString),
                                      linearScaling: ((linearScaling as? NSNumber)?.intValue ?? 0) != 0 ? linearScaling : nil,
                                      accelerationKey: accelerationKey,
                                      acceleration: ((acceleration as? NSNumber)?.intValue ?? 0) < 0 ? acceleration : nil)
        }
        let original = configured[id]!

        let resolution = ((IOHIDServiceClientCopyProperty(service, Key.resolution as CFString) as? NSNumber)?.doubleValue).map { $0 / 65536 } ?? 400
        let table = WindowsPointerBallistics.accelerationTable(speed: config.speed, resolution: resolution > 0 ? resolution : 400) as CFData
        guard Self.setRegistryProperty(id, Key.table, table) else {
            DDLogWarn("WindowsPointerAcceleration: Couldn't set the acceleration table on service \(id)")
            return
        }
        set(service, Key.multiplier, Self.fixed(WindowsPointerBallistics.velocityMultiplier))
        if original.linearScaling != nil {
            set(service, Key.linearScaling, NSNumber(value: 0))
        }
        if original.acceleration != nil { /// Negative = acceleration turned off completely. The driver then skips the table.
            set(service, accelerationKey, NSNumber(value: 0))
        }
        set(service, Key.algorithm, NSNumber(value: Algorithm.table)) /// Last – this one makes the driver rebuild its accelerator

        DDLogInfo("WindowsPointerAcceleration: Applied to service \(id) (resolution \(resolution), speed \(config.speed))")
    }

    private func restoreAll() {
        for (id, original) in configured {
            let service = original.service
            /// Put the table back first. Many mice use the table even in Default mode (when they have no parametric curves), and setting the algorithm below makes the filter rebuild with it.
            if !Self.setRegistryProperty(id, Key.table, original.table ?? (WindowsPointerBallistics.appleDefaultTable as CFData)) {
                DDLogWarn("WindowsPointerAcceleration: Couldn't restore the acceleration table on service \(id)")
            }
            set(service, Key.algorithm, NSNumber(value: Algorithm.normal))
            set(service, Key.multiplier, original.multiplier ?? Self.fixed(1))
            if let linearScaling = original.linearScaling {
                set(service, Key.linearScaling, linearScaling)
            }
            if let acceleration = original.acceleration {
                set(service, original.accelerationKey, acceleration)
            }
            DDLogInfo("WindowsPointerAcceleration: Restored service \(id)")
        }
        configured.removeAll()
    }

    // MARK: Helpers

    /// The HID services (pointer event drivers) of the devices MMF manages, by registry ID
    private func mouseServices() -> [UInt64: IOHIDServiceClient] {

        guard let client else { return [:] }

        var deviceIDs = Set<UInt64>()
        for case let device as Device in DeviceManager.attachedDevices {
            var id: UInt64 = 0
            if let iohidDevice = device.iohidDevice, IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(iohidDevice), &id) == KERN_SUCCESS {
                deviceIDs.insert(id)
            }
        }
        guard !deviceIDs.isEmpty else { return [:] }

        var result: [UInt64: IOHIDServiceClient] = [:]
        for service in (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? [] {
            guard IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0 ||
                  IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Pointer)) != 0,
                  let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value,
                  Self.registryEntry(id, descendsFromOneOf: deviceIDs) else {
                continue
            }
            result[id] = service
        }
        return result
    }

    /// Whether the registry entry is one of `ancestorIDs` or below one of them. (A mouse's HID service sits a few levels below its IOHIDDevice.)
    private static func registryEntry(_ id: UInt64, descendsFromOneOf ancestorIDs: Set<UInt64>) -> Bool {
        var entry = IOServiceGetMatchingService(mach_port_t(MACH_PORT_NULL), IORegistryEntryIDMatching(id))
        for _ in 0..<8 where entry != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS, ancestorIDs.contains(entryID) {
                IOObjectRelease(entry)
                return true
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = result == KERN_SUCCESS ? parent : 0
        }
        if entry != 0 {
            IOObjectRelease(entry)
        }
        return false
    }

    private static func originalTable(of service: IOHIDServiceClient) -> CFTypeRef? {
        let table = IOHIDServiceClientCopyProperty(service, Key.table as CFString)
        return WindowsPointerBallistics.isOurTable(table) ? nil : table /// Ours if the Helper didn't get to restore it last time
    }

    /// Sets a property on the driver's registry entry. It ends up in the entry's `HIDEventServiceProperties`, where the pointer filter finds it.
    ///     Needed for the table: `IOHIDServiceClientSetProperty()` only forwards keys the driver knows to the driver, and the filter itself only keeps the keys it caches (e.g. the algorithm). Measured on AppleUserHIDEventDriver (macOS 27).
    private static func setRegistryProperty(_ id: UInt64, _ key: String, _ value: CFTypeRef) -> Bool {
        let entry = IOServiceGetMatchingService(mach_port_t(MACH_PORT_NULL), IORegistryEntryIDMatching(id))
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        return IORegistryEntrySetCFProperty(entry, key as CFString, value) == KERN_SUCCESS
    }

    private func set(_ service: IOHIDServiceClient, _ key: String, _ value: CFTypeRef) {
        if !IOHIDServiceClientSetProperty(service, key as CFString, value) {
            DDLogWarn("WindowsPointerAcceleration: Couldn't set \(key) on service \(String(describing: IOHIDServiceClientGetRegistryID(service)))")
        }
    }

    private static func fixed(_ value: Double) -> NSNumber {
        return NSNumber(value: Int32((value * 65536).rounded()))
    }

    private func locked(_ work: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        work()
    }
}
