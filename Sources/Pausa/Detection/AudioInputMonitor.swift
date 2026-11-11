import CoreAudio
import Foundation

/// Reads whether any *physical* input audio device is running somewhere.
/// Uses kAudioDevicePropertyDeviceIsRunningSomewhere: query only, no TCC prompt.
/// Static device metadata (name, UID, transport, stream check) is cached and invalidated only when
/// CoreAudio notifies `kAudioHardwarePropertyDevices` changes, so per-second ticks only read one
/// `UInt32` (`kAudioDevicePropertyDeviceIsRunningSomewhere`) per non-virtual input device.
struct AudioInputDevice: CustomStringConvertible {
    let id: AudioObjectID
    let name: String
    let uid: String
    let transport: UInt32
    let isRunning: Bool
    let isVirtual: Bool

    var description: String {
        "\(name) [\(transportName)]\(isVirtual ? " (excluded)" : "") running=\(isRunning)"
    }

    var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeAutoAggregate: return "auto-aggregate"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity"
        case 0: return "unknown"
        default: return String(format: "0x%08x", transport)
        }
    }
}

enum AudioInputMonitor {
    /// Case-insensitive substrings of device names that are never a "meeting".
    static let excludedNameFragments: [String] = [
        "LarkAudioDevice", "Microsoft Teams Audio", "BlackHole", "Loopback",
        "Soundflower", "ZoomAudioDevice", "WeMeet", "腾讯会议", "Krisp",
        "Background Music", "eqMac", "Audio Hijack", "CADefaultDeviceAggregate",
    ]

    private struct CachedDevice {
        let id: AudioObjectID
        let name: String
        let uid: String
        let transport: UInt32
        let isVirtual: Bool
    }

    private final class DeviceCache: @unchecked Sendable {
        let lock = NSLock()
        var devices: [CachedDevice]?
        var listenerInstalled = false
        let listenerQueue = DispatchQueue(label: "pausa.audio.devices", qos: .utility)
    }

    private static let cache = DeviceCache()

    static func isExcluded(name: String, transport: UInt32) -> Bool {
        if transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate {
            return true
        }
        let lower = name.lowercased()
        return excludedNameFragments.contains { lower.contains($0.lowercased()) }
    }

    private static func ensureDeviceListenerLocked() {
        guard !cache.listenerInstalled else { return }
        cache.listenerInstalled = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, cache.listenerQueue) { _, _ in
            cache.lock.lock()
            cache.devices = nil
            cache.lock.unlock()
        }
    }

    private static func cachedInputDevices() -> [CachedDevice] {
        cache.lock.lock()
        ensureDeviceListenerLocked()
        if let existing = cache.devices {
            cache.lock.unlock()
            return existing
        }
        cache.lock.unlock()

        let loaded = loadStaticInputDevices()
        cache.lock.lock()
        cache.devices = loaded
        cache.lock.unlock()
        return loaded
    }

    private static func loadStaticInputDevices() -> [CachedDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInputStreams(id) else { return nil }
            let name = stringProp(id, kAudioObjectPropertyName) ?? "?"
            let uid = stringProp(id, kAudioDevicePropertyDeviceUID) ?? ""
            let transport = u32Prop(id, kAudioDevicePropertyTransportType) ?? 0
            return CachedDevice(id: id, name: name, uid: uid, transport: transport,
                                isVirtual: isExcluded(name: name, transport: transport))
        }
    }

    static func inputDevices() -> [AudioInputDevice] {
        cachedInputDevices().map { d in
            let running = isDeviceRunning(d.id)
            return AudioInputDevice(id: d.id, name: d.name, uid: d.uid, transport: d.transport,
                                    isRunning: running, isVirtual: d.isVirtual)
        }
    }

    /// True if any non-excluded input device is running (queries only `IsRunningSomewhere` on physical devices).
    static func anyPhysicalInputRunning() -> Bool {
        cachedInputDevices().contains { !$0.isVirtual && isDeviceRunning($0.id) }
    }

    private static func isDeviceRunning(_ id: AudioObjectID) -> Bool {
        (u32Prop(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
    }

    private static func hasInputStreams(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func u32Prop(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func stringProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr, let s = v else { return nil }
        return s.takeRetainedValue() as String
    }
}
