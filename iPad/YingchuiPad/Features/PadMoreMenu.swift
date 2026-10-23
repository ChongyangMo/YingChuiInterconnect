import SwiftUI

struct PadMoreMenu: View {
    let model: PadConnectionModel
    var onExitFullScreen: (() -> Void)? = nil
    var showKeyboard: () -> Void
    @State private var diagnosticExport: DiagnosticExport?

    var body: some View {
        StableMenuButton(isFullScreen: onExitFullScreen != nil) {
            PadMoreMenuItems(model: model, showKeyboard: showKeyboard,
                             exitFullScreen: onExitFullScreen) { text in
                diagnosticExport = DiagnosticExport(text: text)
            }.makeItems()
        }
        .frame(width: 44, height: 44)
        .sheet(item: $diagnosticExport) { item in
            DiagnosticActivitySheet(text: item.text)
        }
    }
}

private struct DiagnosticExport: Identifiable {
    let id = UUID()
    let text: String
}

private struct DiagnosticActivitySheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
