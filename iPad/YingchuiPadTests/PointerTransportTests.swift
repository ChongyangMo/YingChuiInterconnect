import Network
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class PointerTransportTests: XCTestCase {
    @MainActor
    func testMovementReachesMacBeforeDownAndBeforeUpEvenWithinOneFlushInterval() async throws {
        let messages = try await collect(expected: 5) { model in
            model.sendPointerDelta(x: 10, y: 20)
            model.sendMouseButton(button: .left, pressed: true)
            model.sendPointerDelta(x: 30, y: 40)
            model.sendPointerDelta(x: 5, y: 6)
            model.sendMouseButton(button: .left, pressed: false)
            model.sendScroll(deltaY: 10)
        }
        XCTAssertEqual(messages.map(\.kind), [.pointerMove, .mouseButton, .pointerMove, .mouseButton, .scroll])
        XCTAssertEqual(messages[0].deltaX, 10)
        XCTAssertEqual(messages[1].pressed, true)
        XCTAssertEqual(messages[2].deltaX, 35)
        XCTAssertEqual(messages[2].deltaY, 46)
        XCTAssertEqual(messages[3].pressed, false)
    }

    @MainActor
    func testQueuedOldSessionInputCannotMoveOrPressOnNewSession() async throws {
        let messages = try await collect(expected: 2) { model in
            // 暂停的是测试队列，保证在发送前完成会话切换，稳定复现旧指令串入新会话。
            model.networkQueue.suspend()
            model.sendPointerDelta(x: 100, y: 100)
            model.sendMouseButton(button: .left, pressed: true)
            model.sendScroll(deltaY: 100)
            model.connectionEpoch.set(UUID())
            model.networkQueue.resume()
            model.sendMouseClick(button: .right)
        }
        XCTAssertEqual(messages.map(\.kind), [.mouseButton, .mouseButton])
        XCTAssertTrue(messages.allSatisfy { $0.button == .right })
        XCTAssertEqual(messages.compactMap(\.pressed), [true, false])
    }

    @MainActor
    func testSeparatedCursorCoalescesToLatestPositionAndClicksCarryExactEndpoint() async throws {
        let stream = UUID()
        let messages = try await collect(expected: 4) { model in
            model.activeStreamID = stream
            try model.videoRenderer.cursor.configure(streamID: stream, state: CursorTests.state())
            model.sendPointerDelta(x: 10, y: 20)
            model.sendPointerDelta(x: 30, y: 40)
            model.sendMouseButton(button: .left, pressed: true)
            model.sendPointerDelta(x: 5, y: 6)
            model.sendMouseButton(button: .left, pressed: false)
        }
        XCTAssertEqual(messages.map(\.kind), [.pointerMove, .mouseButton, .pointerMove, .mouseButton])
        XCTAssertTrue(messages.allSatisfy { $0.streamID == stream })
        XCTAssertEqual(messages[0].cursorInput?.position, .init(x: 140, y: 160))
        XCTAssertEqual(messages[1].cursorInput?.position, messages[0].cursorInput?.position)
        XCTAssertEqual(messages[2].cursorInput?.position, .init(x: 145, y: 166))
        XCTAssertEqual(messages[3].cursorInput?.position, messages[2].cursorInput?.position)
        let sequences = messages.compactMap { $0.cursorInput?.sequence }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, 4)
    }

    @MainActor
    private func collect(expected: Int, send: (PadConnectionModel) throws -> Void) async throws -> [WireMessage] {
        let model = PadConnectionModel()
        let queue = DispatchQueue(label: "pointer.transport.test")
        let listener = try NWListener(using: .tcp, on: .any)
        let listening = expectation(description: "鼠标测试接收端已就绪")
        let connected = expectation(description: "鼠标测试发送端已连接")
        let received = expectation(description: "鼠标事件已收到")
        let collector = PointerWireCollector(expected: expected, completed: received)
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
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
            if case .failed(let error) = state { XCTFail(error.localizedDescription) }
        }
        connection.start(queue: model.networkQueue)
        defer { connection.cancel() }
        await fulfillment(of: [connected], timeout: 5)
        model.networkQueue.sync { model.connection = connection }
        model.isPaired = true
        try send(model)
        await fulfillment(of: [received], timeout: 5)
        return collector.snapshot()
    }
}

private final class PointerWireCollector: @unchecked Sendable {
    var connection: NWConnection?
    private let lock = NSLock()
    private var decoder = WireMessageDecoder()
    private var messages: [WireMessage] = []
    private let expected: Int
    private let completed: XCTestExpectation

    init(expected: Int, completed: XCTestExpectation) { self.expected = expected; self.completed = completed }
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
            if ended { XCTFail("鼠标测试通道提前关闭"); return }
            self.receive()
        }
    }
}
