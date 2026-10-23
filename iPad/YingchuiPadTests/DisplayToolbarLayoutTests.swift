import SwiftUI
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class DisplayToolbarLayoutTests: XCTestCase {
    @MainActor
    func testToolbarFitsPortraitLandscapeAndLargeText() {
        let model = PadConnectionModel(startServices: false)
        model.isStreaming = true
        model.resolutionOptions = [.native]
        model.resolutionViewport = StreamDimensions(width: 2224, height: 1668)
        for width: CGFloat in [343, 500, 760, 1080] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let view = PadVideoToolbar(model: model, isFullScreen: .constant(false))
                    .environment(\.dynamicTypeSize, size)
                    .environment(\.colorScheme, .dark)
                let controller = UIHostingController(rootView: view)
                let fitted = controller.sizeThatFits(in: CGSize(width: width, height: 1000))
                XCTAssertLessThanOrEqual(fitted.width, width + 1, "工具栏不能超出可用宽度：\(width)，\(size)")
                XCTAssertGreaterThanOrEqual(fitted.height, 44)
                XCTAssertLessThan(fitted.height, 500)
            }
        }
    }
}
