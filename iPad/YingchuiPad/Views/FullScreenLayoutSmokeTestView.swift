import SwiftUI

#if DEBUG
struct FullScreenLayoutSmokeTestView: View {
    @StateObject private var model = PadConnectionModel()

    var body: some View {
        FullScreenVideoView(
            model: model,
            isPresented: .constant(true)
        )
    }
}
#endif
