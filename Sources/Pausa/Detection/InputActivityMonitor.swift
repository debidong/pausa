import CoreGraphics
import AppKit

/// §4 typing / dragging. Reads the session's per-event-type idle counters only; installs no event
/// tap, so no Input Monitoring / Accessibility prompt (verified on macOS 27.2, fcBowena).
enum InputActivityMonitor {
    /// Keyboard input within this window counts as "still typing" (design: 3 s).
    static var typingWindow: Double = 3

    static func secondsSinceKey() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }
    static func secondsSinceDrag() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDragged)
    }

    /// True while the user is mid-sentence or holding a drag.
    static func isBusy() -> Bool {
        if secondsSinceKey() < typingWindow { return true }
        // Left button held (drag in progress, even if the pointer is momentarily still).
        if NSEvent.pressedMouseButtons & 1 != 0 && secondsSinceDrag() < 30 { return true }
        return secondsSinceDrag() < 1
    }
}
