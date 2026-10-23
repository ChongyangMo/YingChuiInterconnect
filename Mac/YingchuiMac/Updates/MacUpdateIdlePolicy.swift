import AppKit

struct MacUpdateIdleSnapshot: Equatable {
    var streaming = false
    var connections = 0
    var displayRecovery = false
    var accountOperation = false
    var unsavedEdits = false
    var modalOperation = false
    var canInstall: Bool {
        !streaming && connections == 0 && !displayRecovery && !accountOperation && !unsavedEdits && !modalOperation
    }
}

@MainActor
enum MacUpdateIdlePolicy {
    static func snapshot(host: MacHostModel, account: AccountModel) -> MacUpdateIdleSnapshot {
        let windows = NSApplication.shared.windows
        let editing = NSDocumentController.shared.documents.contains(where: \.isDocumentEdited)
            || windows.contains(where: \.isDocumentEdited)
            || windows.contains {
                guard let editor = $0.firstResponder as? NSTextView else { return false }
                return editor.isEditable && (editor.hasMarkedText() || !editor.string.isEmpty)
            }
        return MacUpdateIdleSnapshot(streaming: host.isStreaming, connections: host.connectedClientCount,
            displayRecovery: host.hasPendingDisplayRecovery || host.activeDisplayState != nil,
            accountOperation: account.isBusy,
            unsavedEdits: editing,
            modalOperation: NSApplication.shared.modalWindow != nil || windows.contains { $0.attachedSheet != nil })
    }
}
