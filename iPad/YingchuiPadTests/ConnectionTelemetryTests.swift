import Combine
import Observation
import XCTest
import YingchuiProtocol
@testable import YingchuiPad

final class ConnectionTelemetryTests: XCTestCase {
    @MainActor
    func testStatisticsNotifyTheirReadersWithoutInvalidatingTheConnectionSurface() {
        let model = PadConnectionModel(startServices: false)
        var connectionChanges = 0
        let observer = model.objectWillChange.sink { connectionChanges += 1 }
        defer { observer.cancel() }
        let statisticsChanged = SynchronizedValue(false)
        withObservationTracking {
            _ = model.videoFramesDecoded
            _ = model.roundTripMilliseconds
        } onChange: { statisticsChanged.set(true) }
        model.videoFramesDecoded = 42
        model.roundTripMilliseconds = 12
        XCTAssertTrue(statisticsChanged.value)
        XCTAssertEqual(model.videoFramesDecoded, 42)
        XCTAssertEqual(model.roundTripMilliseconds, 12)
        XCTAssertEqual(connectionChanges, 0)
        model.isConnected = true
        XCTAssertEqual(connectionChanges, 1)
    }
}
