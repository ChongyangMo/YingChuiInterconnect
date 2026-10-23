import SwiftUI

struct PadAccountSheet: View {
    @ObservedObject var account: AccountModel
    @State private var contentHeight: CGFloat = 240

    var body: some View {
        ScrollView {
            AccountView(account: account)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .presentationDetents(account.user == nil ? [.medium, .large] : [.height(max(240, contentHeight + 12)), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.background)
    }
}
