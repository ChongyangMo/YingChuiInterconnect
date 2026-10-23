import SwiftUI
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class RemoteKeyboardRenderTests: XCTestCase {
    @MainActor
    func testNumberRowAppearanceInBothLanguages() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let model = PadConnectionModel()
        model.isPaired = true
        let state = RemoteKeyboardState()
        let root = FloatingRemoteKeyboard(model: model, state: state, onSystemKeyboard: {}, onClose: {})
            .frame(width: 512, height: 326)
            .background(Color.gray)
            .preferredColorScheme(.dark)
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 512, height: 326)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey(); model.isPaired = false }
        for language in [RemoteKeyboardLanguage.english, .pinyin] {
            model.remoteKeyboardLanguage = language
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                XCTAssertTrue(controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = language == .english ? "英文数字键盘" : "中文数字键盘"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
