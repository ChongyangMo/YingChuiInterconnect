import AuthenticationServices
import SwiftUI

#if os(macOS)
import AppKit

struct AppleAccountButton: NSViewRepresentable {
    var title: String? = nil
    var compact = false
    let action: (ASPresentationAnchor?) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.image = NSImage(systemSymbolName: "applelogo", accessibilityDescription: nil)
        button.symbolConfiguration = .init(pointSize: 24, weight: .regular)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.contentTintColor = .labelColor
        button.toolTip = "通过 Apple 登录"
        button.setAccessibilityLabel("通过 Apple 登录")
        button.setAccessibilityIdentifier("account-apple-login")
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) {
        view.isEnabled = isEnabled
        view.title = title.map { "  " + $0 } ?? ""
        view.imagePosition = title == nil ? .imageOnly : .imageLeading
        view.imageHugsTitle = true
        view.symbolConfiguration = .init(pointSize: title == nil ? 24 : (compact ? 15 : 18), weight: .regular)
        view.font = .preferredFont(forTextStyle: compact ? .callout : .body)
        view.contentTintColor = compact ? .linkColor : .labelColor
        view.toolTip = title ?? "通过 Apple 登录"
        view.setAccessibilityLabel(title ?? "通过 Apple 登录")
        view.setAccessibilityIdentifier(title == nil ? "account-apple-login" : "account-apple-bind")
        context.coordinator.action = action
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        guard compact else { return nil }
        let size = nsView.intrinsicContentSize
        return CGSize(width: size.width, height: max(28, size.height))
    }

    final class Coordinator: NSObject {
        var action: (ASPresentationAnchor?) -> Void
        init(action: @escaping (ASPresentationAnchor?) -> Void) { self.action = action }
        @MainActor @objc func clicked(_ sender: NSButton) { action(sender.window) }
    }
}
#else
import UIKit

struct AppleAccountButton: UIViewRepresentable {
    var title: String? = nil
    var compact = false
    let action: (ASPresentationAnchor?) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "applelogo"), for: .normal)
        button.setPreferredSymbolConfiguration(.init(pointSize: 24, weight: .regular), forImageIn: .normal)
        button.tintColor = .label
        button.addTarget(context.coordinator, action: #selector(Coordinator.clicked(_:)), for: .touchUpInside)
        button.accessibilityLabel = "通过 Apple 登录"
        button.accessibilityIdentifier = "account-apple-login"
        return button
    }

    func updateUIView(_ view: UIButton, context: Context) {
        view.isEnabled = isEnabled
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "applelogo")
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: title == nil ? 24 : (compact ? 15 : 18), weight: .regular)
        view.setPreferredSymbolConfiguration(configuration.preferredSymbolConfigurationForImage, forImageIn: .normal)
        configuration.title = title
        configuration.imagePadding = 8
        configuration.baseForegroundColor = compact ? .link : .label
        if compact {
            configuration.contentInsets = .zero
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attributes = incoming
                attributes.font = UIFont.preferredFont(forTextStyle: .callout)
                return attributes
            }
        }
        view.configuration = configuration
        view.accessibilityLabel = title ?? "通过 Apple 登录"
        view.accessibilityIdentifier = title == nil ? "account-apple-login" : "account-apple-bind"
        context.coordinator.action = action
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        guard compact else { return nil }
        let size = uiView.intrinsicContentSize
        return CGSize(width: size.width, height: max(44, size.height))
    }

    final class Coordinator: NSObject {
        var action: (ASPresentationAnchor?) -> Void
        init(action: @escaping (ASPresentationAnchor?) -> Void) { self.action = action }
        @MainActor @objc func clicked(_ sender: UIButton) { action(sender.window) }
    }
}
#endif
