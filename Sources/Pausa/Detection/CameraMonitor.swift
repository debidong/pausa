import CoreMediaIO
import Foundation

/// Reads whether any camera is running somewhere via CoreMediaIO.
/// Query only, no camera permission needed.
enum CameraMonitor {
    struct Camera: CustomStringConvertible {
        let name: String
        let isRunning: Bool
        var description: String { "\(name) running=\(isRunning)" }
    }

    static func cameras() -> [Camera] {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids.map { Camera(name: name($0) ?? "?", isRunning: isRunning($0)) }
    }

    static func anyRunning() -> Bool { cameras().contains { $0.isRunning } }

    private static func isRunning(_ id: CMIOObjectID) -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        var v: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &v) == noErr && v != 0
    }

    private static func name(_ id: CMIOObjectID) -> String? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        var v: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &v) == noErr, let s = v else { return nil }
        return s.takeRetainedValue() as String
    }
}
