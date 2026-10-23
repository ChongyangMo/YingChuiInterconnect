import AVFoundation
import SwiftUI
import XCTest
@testable import YingchuiPad

final class RemoteKeyboardLayoutTests: XCTestCase {
    @MainActor
    func testKeyboardLeavesVideoVisibleWithoutChangingStreamViewport() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let state = KeyboardLayoutState()
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: KeyboardLayoutHarness(state: state))
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.view.endEditing(true)
            window.isHidden = true
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))
        let surface = try XCTUnwrap(findView(SampleBufferView.self, in: controller.view))
        let originalFrame = surface.convert(surface.bounds, to: window)
        let originalViewport = try XCTUnwrap(state.viewports.last)

        for _ in 0..<3 {
            state.showKeyboard = true
            try await Task.sleep(for: .seconds(1))
            let input = try XCTUnwrap(findView(UITextField.self, in: controller.view))
            XCTAssertTrue(input.isFirstResponder)
            let visibleFrame = surface.convert(surface.bounds, to: window)
            let inputFrame = input.convert(input.bounds, to: window)
            XCTAssertGreaterThan(visibleFrame.height, 100)
            XCTAssertLessThan(visibleFrame.height, originalFrame.height - 150,
                              "原生键盘应当压缩可见画面区域")
            XCTAssertLessThanOrEqual(visibleFrame.maxY, inputFrame.minY + 1,
                                     "输入栏不能覆盖远程画面")
            XCTAssertEqual(surface.sampleBufferLayer.videoGravity, .resizeAspect)
            XCTAssertTrue(state.viewports.allSatisfy { $0 == originalViewport },
                          "打开键盘不能改变回传分辨率")
            XCTAssertNil(controller.presentedViewController, "键盘输入不能创建弹窗")
            state.showKeyboard = false
            try await Task.sleep(for: .milliseconds(700))
            let restored = surface.convert(surface.bounds, to: window)
            XCTAssertEqual(restored.height, originalFrame.height, accuracy: 1)
        }
    }

    func testFloatingKeyboardStaysReachableAtWindowEdges() {
        let panel = CGSize(width: 476, height: 290)
        let window = CGSize(width: 1112, height: 834)
        let topLeft = FloatingKeyboardPlacement.clamp(CGPoint(x: -1000, y: -1000), panel: panel, container: window)
        let bottomRight = FloatingKeyboardPlacement.clamp(CGPoint(x: 5000, y: 5000), panel: panel, container: window)
        XCTAssertEqual(topLeft, CGPoint(x: 246, y: 153))
        XCTAssertEqual(bottomRight, CGPoint(x: 866, y: 681))
    }

    @MainActor
    func testFloatingKeyboardKeepsFullScreenAndDoesNotOpenSystemKeyboard() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let state = KeyboardLayoutState()
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: FloatingKeyboardLayoutHarness(state: state))
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(300))
        let surface = try XCTUnwrap(findView(SampleBufferView.self, in: controller.view))
        let originalFrame = surface.convert(surface.bounds, to: window)
        let originalViewport = try XCTUnwrap(state.viewports.last)
        for _ in 0..<3 {
            state.showKeyboard = true
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(surface.convert(surface.bounds, to: window), originalFrame)
            let capture = try XCTUnwrap(findView(RemoteTypingTextField.self, in: controller.view))
            XCTAssertTrue(capture.isFirstResponder)
            XCTAssertNotNil(capture.inputView)
            XCTAssertEqual(capture.inputView?.bounds.height, 0)
            XCTAssertEqual(originalFrame.height, window.bounds.height, accuracy: 1)
            XCTAssertNil(controller.presentedViewController)
            XCTAssertTrue(state.viewports.allSatisfy { $0 == originalViewport })
            state.showKeyboard = false
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    private func findView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.findView(type, in: $0) }.first
    }
}

@MainActor
private final class KeyboardLayoutState: ObservableObject {
    @Published var showKeyboard = false
    var viewports: [CGSize] = []
}

private struct KeyboardLayoutHarness: View {
    @ObservedObject var state: KeyboardLayoutState
    @StateObject private var model = PadConnectionModel()
    @StateObject private var keyboardState = RemoteKeyboardState()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FullScreenVideoSurface(renderer: model.videoRenderer) { state.viewports.append($0) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if state.showKeyboard {
                RemoteKeyboardDock(model: model, state: keyboardState) { state.showKeyboard = false }
            }
        }
        .ignoresSafeArea(.container)
    }
}

private struct FloatingKeyboardLayoutHarness: View {
    @ObservedObject var state: KeyboardLayoutState
    @StateObject private var model = PadConnectionModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FullScreenVideoSurface(renderer: model.videoRenderer) { state.viewports.append($0) }
        }
        .modifier(RemoteKeyboardPresentation(model: model, isPresented: $state.showKeyboard))
        .ignoresSafeArea(.container)
        .onAppear { model.isPaired = true }
        .onDisappear { model.isPaired = false }
    }
}
