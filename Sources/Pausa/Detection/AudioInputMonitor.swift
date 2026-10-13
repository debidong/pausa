import CoreAudio
import Foundation

/// Reads whether any *physical* input audio device is running somewhere.
/// Uses kAudioDevicePropertyDeviceIsRunningSomewhere: query only, no TCC prompt.
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

    static func isExcluded(name: String, transport: UInt32) -> Bool {
        if transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate {
            return true
        }
        let lower = name.lowercased()
        return excludedNameFragments.contains { lower.contains($0.lowercased()) }
    }

    static func inputDevices() -> [AudioInputDevice] {
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
            let running = (u32Prop(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
            return AudioInputDevice(id: id, name: name, uid: uid, transport: transport,
                                    isRunning: running, isVirtual: isExcluded(name: name, transport: transport))
        }
    }

    /// True if any non-excluded input device is running.
    static func anyPhysicalInputRunning() -> Bool {
        inputDevices().contains { $0.isRunning && !$0.isVirtual }
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
