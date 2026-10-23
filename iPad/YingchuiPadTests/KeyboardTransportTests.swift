import Network
import XCTest
@testable import YingchuiPad
import YingchuiProtocol

final class KeyboardTransportTests: XCTestCase {
    @MainActor
    func testRapidTypingDoesNotWaitForOlderTextAcknowledgements() async throws {
        let messages = try await collect(expected: 202) { model in
            for _ in 0..<100 {
                model.sendKeyboardText("a")
                model.sendKeyboardText("你")
            }
            model.sendKeyPress(.deleteBackward)
            model.sendKeyPress(.returnKey)
        }
        XCTAssertEqual(messages.prefix(200).compactMap(\.text).joined(), String(repeating: "a你", count: 100))
        XCTAssertEqual(messages.suffix(2).compactMap(\.key), [.deleteBackward, .returnKey])
        XCTAssertEqual(messages.count, 202)
    }

    @MainActor
    func testPinyinIsSentAsOrderedPhysicalKeys() async throws {
        let messages = try await collect(expected: 7) { model in
            model.remoteKeyboardLanguage = .pinyin
            model.sendFloatingKeyboardText("nihao 1")
        }
        XCTAssertTrue(messages.allSatisfy { $0.kind == .keyPress && $0.text == nil })
        XCTAssertEqual(messages.compactMap(\.key), [.letterN, .letterI, .letterH, .letterA, .letterO, .space, .digit1])
    }

    @MainActor
    func testNumberRowAndLongPressSymbolsKeepEnglishAndPinyinInputOrder() async throws {
        let digits = "1234567890"
        let symbols = "!@#$%^&*(),.\"'"
        let english = try await collect(expected: 24) { model in
            for character in digits + symbols { model.sendFloatingKeyboardText(String(character)) }
        }
        XCTAssertTrue(english.allSatisfy { $0.kind == .textInput })
        XCTAssertEqual(english.compactMap(\.text).joined(), digits + symbols)

        let pinyin = try await collect(expected: 24) { model in
            model.remoteKeyboardLanguage = .pinyin
            for character in digits + symbols { model.sendFloatingKeyboardText(String(character)) }
        }
        let keys: [RemoteKey] = [.digit1, .digit2, .digit3, .digit4, .digit5,
                                 .digit6, .digit7, .digit8, .digit9, .digit0]
        XCTAssertTrue(pinyin.allSatisfy { $0.kind == .keyPress })
        XCTAssertEqual(pinyin.compactMap(\.key), keys + keys + [.comma, .period, .quote, .quote])
        XCTAssertTrue(pinyin[10..<20].allSatisfy { $0.modifiers == [.shift] })
        XCTAssertEqual(pinyin[20].modifiers, [])
        XCTAssertEqual(pinyin[21].modifiers, [])
        XCTAssertEqual(pinyin[22].modifiers, [.shift])
        XCTAssertEqual(pinyin[23].modifiers, [])
    }

    @MainActor
    private func collect(expected: Int, send: (PadConnectionModel) -> Void) async throws -> [WireMessage] {
        let model = PadConnectionModel()
        let queue = DispatchQueue(label: "keyboard.transport.test")
        let listener = try NWListener(using: .tcp, on: .any)
        let listening = expectation(description: "测试接收端已就绪")
        let connected = expectation(description: "测试发送端已连接")
        let received = expectation(description: "所有键盘事件已收到")
        let collector = KeyboardWireCollector(expected: expected, completed: received)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
            if case .failed(let error) = state { XCTFail(error.localizedDescription) }
        }
        listener.newConnectionHandler = { connection in
            collector.connection = connection
            connection.start(queue: queue)
            collector.receive()
        }
        listener.start(queue: queue)
        defer { listener.cancel(); collector.connection?.cancel() }
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
            if case .failed(let error) = state { XCTFail(error.localizedDescription) }
        }
        connection.start(queue: model.networkQueue)
        defer { connection.cancel() }
        await fulfillment(of: [connected], timeout: 5)
        model.networkQueue.sync {
            model.connection = connection
            model.pendingTextIDs.insert(UUID())
        }
        model.isPaired = true
        send(model)
        await fulfillment(of: [received], timeout: 5)
        return collector.snapshot()
    }
}

private final class KeyboardWireCollector: @unchecked Sendable {
    var connection: NWConnection?
    private let lock = NSLock()
    private var decoder = WireMessageDecoder()
    private var messages: [WireMessage] = []
    let expected: Int
    let completed: XCTestExpectation

    init(expected: Int, completed: XCTestExpectation) {
        self.expected = expected
        self.completed = completed
    }

    func snapshot() -> [WireMessage] { lock.lock(); defer { lock.unlock() }; return messages }

    func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            guard let self else { return }
            if let error { XCTFail(error.localizedDescription); return }
            if let data {
                do {
                    let decoded = try self.decoder.append(data)
                    self.lock.lock()
                    self.messages.append(contentsOf: decoded)
                    let done = self.messages.count >= self.expected
                    self.lock.unlock()
                    if done { self.completed.fulfill(); return }
                } catch { XCTFail(error.localizedDescription); return }
            }
            if ended { XCTFail("测试通道提前关闭"); return }
            self.receive()
        }
    }
}
