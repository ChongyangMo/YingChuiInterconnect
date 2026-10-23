#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AuthenticationServices
import Foundation
import Security

@MainActor
final class AppleAccountAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleAccountCredential, Error>?
    private var controller: ASAuthorizationController?
    private var anchor: ASPresentationAnchor?
    private var expectedState: String?
    private var challengeExpiresAt: Date?

    static func requireAuthorized(userID: String) async throws {
        let state = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, Error>) in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
                if error != nil { continuation.resume(throwing: AccountError.appleAuthorizationFailed) }
                else { continuation.resume(returning: state) }
            }
        }
        guard state == .authorized else { throw AccountError.unauthorized }
    }

    static func requireCapability() throws {
#if os(macOS)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw AccountError.appleCapabilityMissing
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw AccountError.appleCapabilityMissing
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let capabilities = entitlements["com.apple.developer.applesignin"] as? [String],
              capabilities.contains("Default") else { throw AccountError.appleCapabilityMissing }
#endif
    }

    func authorize(challenge: AppleAccountChallenge, window: ASPresentationAnchor) async throws -> AppleAccountCredential {
        guard controller == nil else { throw AccountError.operationInProgress }
        try Self.requireCapability()
        guard !challenge.id.isEmpty, !challenge.requestNonce.isEmpty else { throw AccountError.invalidResponse }
        guard challenge.expiresAt > Date() else { throw AccountError.expired }
        let state = try Self.randomState()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = challenge.requestNonce
        request.state = state
        let authorization = ASAuthorizationController(authorizationRequests: [request])
        authorization.delegate = self
        authorization.presentationContextProvider = self
        controller = authorization
        anchor = window
        expectedState = state
        challengeExpiresAt = challenge.expiresAt
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { cancel() } else { authorization.performRequests() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.expectedState == state else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        let previous = controller
        finish(.failure(CancellationError()))
        previous?.cancel()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // 授权期间强持有真实窗口，不使用临时窗口掩盖缺失的展示上下文。
        precondition(anchor != nil, "Apple 授权窗口不存在")
        return anchor!
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard self.controller === controller else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.state == expectedState else {
            finish(.failure(AccountError.appleStateMismatch)); return
        }
        guard let expiresAt = challengeExpiresAt, expiresAt > Date() else {
            finish(.failure(AccountError.expired)); return
        }
        guard let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }), !token.isEmpty,
              let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }), !code.isEmpty,
              !credential.user.isEmpty else {
            finish(.failure(AccountError.invalidResponse)); return
        }
        finish(.success(AppleAccountCredential(userID: credential.user, identityToken: token,
            authorizationCode: code, givenName: credential.fullName?.givenName, familyName: credential.fullName?.familyName)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard self.controller === controller else { return }
        if (error as? ASAuthorizationError)?.code == .canceled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(AccountError.appleAuthorizationFailed))
        }
    }

    private func finish(_ result: Result<AppleAccountCredential, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        anchor = nil
        expectedState = nil
        challengeExpiresAt = nil
        pending?.resume(with: result)
    }

    private static func randomState() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw AccountError.keychain(status) }
        return Data(bytes).base64EncodedString()
    }
}
