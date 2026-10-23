import Combine
import SwiftUI

struct RemoteKeyboardPresentation: ViewModifier {
    @ObservedObject var model: PadConnectionModel
    @Binding var isPresented: Bool
    var isActive = true
    @StateObject private var state = RemoteKeyboardState()
    @State private var useSystemKeyboard = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isActive && isPresented && useSystemKeyboard {
                    RemoteKeyboardDock(model: model, state: state) { useSystemKeyboard = false }
                }
            }
            .overlay {
                if isActive && isPresented && !useSystemKeyboard {
                    FloatingRemoteKeyboard(
                        model: model,
                        state: state,
                        onSystemKeyboard: { useSystemKeyboard = true },
                        onClose: { isPresented = false }
                    )
                }
            }
            .overlay(alignment: .topLeading) {
                if isActive && model.isPaired && !(isPresented && useSystemKeyboard) {
                    RemoteTypingInput(state: state, onText: model.sendFloatingKeyboardText, onKey: model.sendKeyPress)
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                        .accessibilityHidden(true)
                }
            }
            .onDisappear { state.reset() }
            .onChange(of: isPresented) { _, presented in
                if !presented { useSystemKeyboard = false }
            }
    }
}
