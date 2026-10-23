import SwiftUI

struct RemoteKeyboardKeyStyle: ButtonStyle {
    var hardwarePressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = enabled && (configuration.isPressed || hardwarePressed)
        configuration.label
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 44, minHeight: 44)
            .background(pressed ? Color(red: 0.08, green: 0.32, blue: 0.65) : Color(white: 0.08).opacity(0.9),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(pressed ? 0.5 : 0.12), lineWidth: 0.5)
            }
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: pressed ? 0.07 : 0.14), value: pressed)
            .contentShape(Rectangle())
    }
}
