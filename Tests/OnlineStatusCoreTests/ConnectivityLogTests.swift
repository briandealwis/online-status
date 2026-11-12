import Foundation
import XCTest
@testable import OnlineStatusCore

final class ConnectivityLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let home = LogContext(network: "Wi-Fi: Home", location: Coordinate(latitude: 49.28, longitude: -123.12, accuracy: 65))

    private func ok(_ offset: TimeInterval, ms: Double = 30) -> Sample {
        .success(at: t0.addingTimeInterval(offset), rtt: ms / 1000)
    }

    private func fail(_ offset: TimeInterval) -> Sample {
        .failure(at: t0.addingTimeInterval(offset), .timeout)
    }

    func testCoalescesSameStatusIntoOneSegment() {
        var recorder = SegmentRecorder()
        for i in 0..<6 {
            XCTAssertNil(recorder.record(ok(Double(i) * 10, ms: Double(20 + i)), status: .level(.good), context: home))
        }
        let segment = recorder.close(at: t0.addingTimeInterval(60))
        XCTAssertEqual(segment?.start, t0)
        XCTAssertEqual(segment?.end, t0.addingTimeInterval(60))
        XCTAssertEqual(segment?.probes, 6)
        XCTAssertEqual(segment?.failures, 0)
        XCTAssertEqual(segment?.medianRTT ?? 0, 0.0225, accuracy: 1e-9)
        XCTAssertNil(recorder.current)
    }

    func testStatusChangeStartsNewSegmentAtThatSample() {
        var recorder = SegmentRecorder()
        _ = recorder.record(ok(0), status: .level(.good), context: home)
        _ = recorder.record(ok(10), status: .level(.good), context: home)
        let finished = recorder.record(fail(20), status: .level(.mixed), context: home)
        XCTAssertEqual(finished?.status, .level(.good))
        XCTAssertEqual(finished?.end, t0.addingTimeInterval(20), "segments are contiguous")
        XCTAssertEqual(finished?.probes, 2)
        XCTAssertEqual(recorder.current?.status, .level(.mixed))
        XCTAssertEqual(recorder.current?.start, t0.addingTimeInterval(20))
        XCTAssertEqual(recorder.current?.failures, 1)
    }

    func testNetworkChangeDistanceAndDurationSplit() {
        var recorder = SegmentRecorder()
        _ = recorder.record(ok(0), status: .level(.good), context: home)
        let train = LogContext(network: "Wi-Fi: TrainNet", location: home.location)
        XCTAssertEqual(recorder.record(ok(10), status: .level(.good), context: train)?.network, "Wi-Fi: Home")

        // About 1.1 km north.
        let moved = LogContext(network: "Wi-Fi: TrainNet",
                               location: Coordinate(latitude: 49.29, longitude: -123.12, accuracy: 65))
        XCTAssertNotNil(recorder.record(ok(20), status: .level(.good), context: moved))

        recorder.maxDuration = 60
        XCTAssertNil(recorder.record(ok(70), status: .level(.good), context: moved))
        XCTAssertNotNil(recorder.record(ok(80), status: .level(.good), context: moved), "reached max duration")
    }

    func testMeasuringClosesWithoutStartingNew() {
        var recorder = SegmentRecorder()
        _ = recorder.record(ok(0), status: .level(.good), context: home)
        XCTAssertNotNil(recorder.record(ok(10), status: .measuring, context: home))
        XCTAssertNil(recorder.current)
        XCTAssertNil(recorder.record(ok(20), status: .measuring, context: home))
    }

    func testLocationFilledInWhenItArrivesLater() {
        var recorder = SegmentRecorder()
        _ = recorder.record(ok(0), status: .level(.good), context: LogContext(network: "Wi-Fi: Home", location: nil))
        XCTAssertNil(recorder.record(ok(10), status: .level(.good), context: home))
        XCTAssertEqual(recorder.current?.location, home.location)
    }

    func testDistance() {
        let vancouver = Coordinate(latitude: 49.2827, longitude: -123.1207, accuracy: 0)
        let seattle = Coordinate(latitude: 47.6062, longitude: -122.3321, accuracy: 0)
        XCTAssertEqual(vancouver.distance(to: seattle), 195_000, accuracy: 3_000)
        XCTAssertEqual(vancouver.distance(to: vancouver), 0, accuracy: 1e-6)
    }

    func testCSVRow() {
        let formatter = ConnectivityLogCSV.makeDateFormatter(timeZone: TimeZone(identifier: "UTC")!)
        var segment = LogSegment(start: t0, end: t0.addingTimeInterval(95), status: .level(.mixed),
                                 network: "Wi-Fi: Bob's \"Fast\" Net", location: home.location)
        segment.probes = 10
        segment.failures = 1
        segment.rtts = [0.020, 0.030, 0.040]
        XCTAssertEqual(
            ConnectivityLogCSV.row(segment, formatter: formatter),
            "2027-01-15 08:00:00,2027-01-15 08:01:35,95,mixed,\"Wi-Fi: Bob's \"\"Fast\"\" Net\","
                + "49.28000,-123.12000,65,10,1,10.0,30.0"
        )
    }

    func testCSVTextEscaping() {
        XCTAssertEqual(ConnectivityLogCSV.text("Ethernet"), "Ethernet")
        XCTAssertEqual(ConnectivityLogCSV.text("a,b"), "\"a,b\"")
        XCTAssertEqual(ConnectivityLogCSV.text("line\nbreak"), "\"line break\"")
        // Formula injection is neutralised.
        XCTAssertEqual(ConnectivityLogCSV.text("=HYPERLINK(1)"), "\"'=HYPERLINK(1)\"")
        XCTAssertEqual(ConnectivityLogCSV.text("@SUM"), "\"'@SUM\"")
    }

    func testPrune() {
        let formatter = ConnectivityLogCSV.makeDateFormatter(timeZone: TimeZone(identifier: "UTC")!)
        let contents = """
        \(ConnectivityLogCSV.header)
        2026-01-01 10:00:00,2026-01-01 10:05:00,300,good,Ethernet,,,,30,0,0.0,20.0
        2026-06-01 10:00:00,2026-06-01 10:05:00,300,poor,Ethernet,,,,30,9,30.0,20.0
        garbage line

        """
        let cutoff = formatter.date(from: "2026-03-01 00:00:00")!
        XCTAssertEqual(
            ConnectivityLogCSV.prune(contents, before: cutoff, formatter: formatter),
            "\(ConnectivityLogCSV.header)\n"
                + "2026-06-01 10:00:00,2026-06-01 10:05:00,300,poor,Ethernet,,,,30,9,30.0,20.0\n"
                + "garbage line\n"
        )
        XCTAssertEqual(ConnectivityLogCSV.prune("", before: cutoff, formatter: formatter),
                       ConnectivityLogCSV.header + "\n")
    }

    func testLogSettings() {
        let store = UserDefaults(suiteName: "ConnectivityLogTests-\(UUID().uuidString)")!
        var settings = MonitorSettings(defaults: store)
        XCTAssertFalse(settings.logEnabled)
        XCTAssertEqual(settings.logRetentionDays, 90)
        store.set(100_000, forKey: MonitorSettings.Key.logRetentionDays)
        settings = MonitorSettings(defaults: store)
        XCTAssertEqual(settings.logRetentionDays, MonitorSettings.Limit.logRetentionDays)
        store.set(0, forKey: MonitorSettings.Key.logRetentionDays)
        settings = MonitorSettings(defaults: store)
        XCTAssertEqual(settings.logRetentionDays, 0, "0 means keep forever")
    }
}
