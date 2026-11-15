import SwiftUI

/// Dynamic Island–style per-digit spring wheel ("Option B").
/// Only characters that actually changed roll vertically; unchanged digits and separators (`:`)
/// stay completely still. Countdown ticks roll downward (`+1`); postpones (+5m / +15m) roll upward (`-1`).
/// Falls back to a zero-offset gentle cross-dissolve when `accessibilityReduceMotion` is enabled.
struct RollingDigits: View {
    let text: String
    var numericValue: Double = 0
    let size: CGFloat
    var weight: Font.Weight = .semibold

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct SlotModel: Identifiable, Equatable {
        /// Stable identity anchored from the right (0 = rightmost character) so unchanged
        /// higher-order digits never remount or flicker on ordinary 1-second ticks.
        let id: Int
        var current: Character
        var previous: Character?
        var direction: CGFloat
        var base: CGFloat
        var target: CGFloat
    }

    @State private var slots: [SlotModel]
    @State private var renderedText: String
    @State private var lastNumeric: Double

    init(text: String, numericValue: Double = 0, size: CGFloat, weight: Font.Weight = .semibold) {
        self.text = text
        self.numericValue = numericValue
        self.size = size
        self.weight = weight
        _slots = State(initialValue: Self.initialSlots(for: text))
        _renderedText = State(initialValue: text)
        _lastNumeric = State(initialValue: numericValue)
    }

    static func initialSlots(for string: String) -> [SlotModel] {
        let chars = Array(string)
        let n = chars.count
        return chars.enumerated().map { idx, ch in
            SlotModel(id: n - 1 - idx, current: ch, previous: nil, direction: 1, base: 0, target: 0)
        }
    }

    private struct ObservedInput: Equatable {
        let text: String
        let numericValue: Double
    }

    var body: some View {
        let font = Font.system(size: size, weight: weight).monospacedDigit()
        // A hidden `Text` participates in layout so `.firstTextBaseline`, `fittingSize`, and VoiceOver
        // match native single-string `Text` metrics to 0.0 pt while the overlay animates per-slot glyphs.
        Text(renderedText)
            .font(font)
            .opacity(0)
            .accessibilityLabel(renderedText)
            .overlay {
                HStack(alignment: .center, spacing: 0) {
                    ForEach(slots) { slot in
                        WheelGlyphSlot(
                            current: slot.current,
                            previous: slot.previous,
                            direction: slot.direction,
                            base: slot.base,
                            progressTarget: slot.target,
                            size: size,
                            weight: weight,
                            reduceMotion: reduceMotion
                        )
                    }
                }
                .accessibilityHidden(true)
            }
            .modifier(TextChangeObserver(value: ObservedInput(text: text, numericValue: numericValue)) { next in
                transition(to: next.text, newNumeric: next.numericValue)
            })
    }

    /// Pure slot diff from right to left (`changedRightIDs` is ordered right-to-left for stagger).
    static func computeTransition(
        from slots: [SlotModel],
        lastNumeric: Double,
        to nextText: String,
        newNumeric: Double
    ) -> (updated: [SlotModel], changedRightIDs: [Int]) {
        let dir: CGFloat = (newNumeric > lastNumeric) ? -1 : 1
        let nextChars = Array(nextText)
        let n = nextChars.count
        var oldByID: [Int: SlotModel] = [:]
        for s in slots { oldByID[s.id] = s }

        var updated: [SlotModel] = []
        updated.reserveCapacity(n)
        for (idx, ch) in nextChars.enumerated() {
            let rightID = n - 1 - idx
            if var existing = oldByID[rightID] {
                if existing.current != ch {
                    existing.previous = existing.current
                    existing.current = ch
                    existing.direction = dir
                    existing.base = existing.target
                }
                updated.append(existing)
            } else {
                // Newly inserted higher-place digit (e.g. 9:58 + 5m -> 14:58): roll in from empty.
                updated.append(SlotModel(id: rightID, current: ch, previous: " ", direction: dir, base: 0, target: 0))
            }
        }

        var changedRightIDs: [Int] = []
        for i in stride(from: updated.count - 1, through: 0, by: -1) {
            let rightID = updated[i].id
            let didChange = oldByID[rightID].map { $0.current != updated[i].current } ?? true
            if didChange { changedRightIDs.append(rightID) }
        }
        return (updated, changedRightIDs)
    }

    private func transition(to nextText: String, newNumeric: Double) {
        guard nextText != renderedText else {
            lastNumeric = newNumeric
            return
        }

        let step = Self.computeTransition(from: slots, lastNumeric: lastNumeric, to: nextText, newNumeric: newNumeric)
        lastNumeric = newNumeric
        renderedText = nextText
        slots = step.updated

        for (staggerOrder, rightID) in step.changedRightIDs.enumerated() {
            let delay = reduceMotion ? 0 : Double(staggerOrder) * 0.026
            let anim: Animation = reduceMotion
                ? .easeOut(duration: 0.2)
                : .interpolatingSpring(mass: 1, stiffness: 255, damping: 23, initialVelocity: 3).delay(delay)

            withAnimation(anim) {
                if let pos = slots.firstIndex(where: { $0.id == rightID }) {
                    slots[pos].target += 1
                }
            }
        }
    }
}

private struct WheelGlyphSlot: View, Animatable {
    let current: Character
    let previous: Character?
    let direction: CGFloat
    let base: CGFloat
    var progressTarget: CGFloat
    let size: CGFloat
    let weight: Font.Weight
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progressTarget }
        set { progressTarget = newValue }
    }

    var body: some View {
        let font = Font.system(size: size, weight: weight).monospacedDigit()
        if previous == nil {
            Text(String(current))
                .font(font)
        } else {
            let p = max(0, progressTarget - base)
            let travel = reduceMotion ? 0 : size * 0.88
            let outAlpha = Double(max(0, min(1, 1 - p * 1.15)))
            let inAlpha = Double(max(0, min(1, p * 1.25)))
            let sizing = (current.isNumber || current == " ") ? "8" : String(current)

            ZStack {
                Text(sizing)
                    .font(font)
                    .opacity(0)

                if let prev = previous, prev != " ", outAlpha > 0.001 {
                    Text(String(prev))
                        .font(font)
                        .opacity(outAlpha)
                        .offset(y: direction * p * travel)
                }

                Text(String(current))
                    .font(font)
                    .opacity(inAlpha)
                    .offset(y: -direction * (1 - p) * travel)
            }
            .padding(.vertical, size * 0.24)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.14),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .padding(.vertical, -size * 0.24)
        }
    }
}

/// Warning-free `onChange` bridge across macOS 13 and macOS 14+.
private struct TextChangeObserver<V: Equatable>: ViewModifier {
    let value: V
    let action: (V) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            content.onChange(of: value, perform: action)
        }
    }
}
