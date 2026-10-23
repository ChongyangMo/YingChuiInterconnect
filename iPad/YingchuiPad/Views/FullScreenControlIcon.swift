import SwiftUI

struct FullScreenControlIcon: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.blue.opacity(contrast == .increased ? 0.85 : 0.4))
            .accessibilityHidden(true)
    }
}
