import XCTest
@testable import YingchuiProtocol

final class RuntimeJournalTests: XCTestCase {
    func testRotationBoundsFilesAndPreservesLatestEvent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try RuntimeJournal(directory: directory, maximumBytes: 400)
        for index in 0..<100 { try journal.append("测试运行记录 \(index)：持续投屏中") }
        try journal.synchronize()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(names), Set(["runtime.log", "runtime.1.log", "runtime.2.log"]))
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(data.count, 400)
        }
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("runtime.log"), encoding: .utf8).contains("记录 99"))
    }

    func testSessionSurvivesRelaunchAndDistinguishesRecordedExit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try RuntimeJournal(directory: directory)
        XCTAssertNil(try journal.previousSession())
        var session = RuntimeJournal.Session(id: UUID(), processID: 123, startedAt: Date(),
            lastSeenAt: Date(), phase: "前台活动", endedNormally: false)
        try journal.checkpoint(session)
        let reopened = try RuntimeJournal(directory: directory)
        XCTAssertFalse(try XCTUnwrap(reopened.previousSession()).endedNormally)
        session.endedNormally = true
        session.phase = "正常退出"
        try journal.checkpoint(session)
        XCTAssertTrue(try XCTUnwrap(reopened.previousSession()).endedNormally)
        XCTAssertEqual(try reopened.previousSession()?.id, session.id)
    }

    func testCorruptCheckpointReportsErrorInsteadOfPretendingFirstLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try RuntimeJournal(directory: directory)
        try Data("损坏数据".utf8).write(to: directory.appendingPathComponent("session.json"))
        XCTAssertThrowsError(try journal.previousSession())
    }

    func testProcessSnapshotHasPhysicalMemoryAndIncreasingUptime() throws {
        let first = try ProcessResourceSnapshot.read()
        let next = try ProcessResourceSnapshot.read()
        XCTAssertGreaterThan(first.memoryBytes, 0)
        XCTAssertGreaterThanOrEqual(next.cpuSeconds, first.cpuSeconds)
        XCTAssertGreaterThanOrEqual(next.uptime, first.uptime)
    }
}
