import Foundation
import XCTest
@testable import OnlineStatusCore

final class StatusEvaluatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var samples: [Sample] = []
    private var evaluator = StatusEvaluator()

    override func setUp() {
        samples = []
        evaluator = StatusEvaluator()
    }

    /// Adds a sample at `offset` seconds and returns the evaluated status.
    @discardableResult
    private func add(_ offset: TimeInterval, ms: Double? = nil, failure: FailureReason? = nil) -> DisplayStatus {
        let date = t0.addingTimeInterval(offset)
        if let failure {
            samples.append(.failure(at: date, failure))
        } else {
            samples.append(.success(at: date, rtt: (ms ?? 30) / 1000))
        }
        return evaluator.evaluate(samples, now: date)
    }

    func testMeasuringUntilEnoughSamples() {
        XCTAssertEqual(add(0, ms: 30), .measuring)
        XCTAssertEqual(add(10, ms: 30), .level(.good))
    }

    func testFirstFailureLeavesMeasuringImmediately() {
        XCTAssertEqual(add(0, failure: .timeout), .level(.poor))
    }

    func testSlowLatencyIsMixedThenPoor() {
        add(0, ms: 300)
        XCTAssertEqual(add(10, ms: 300), .level(.mixed))
        evaluator.reset()
        samples = []
        add(0, ms: 900)
        XCTAssertEqual(add(10, ms: 900), .level(.poor))
    }

    func testDropsImmediatelyOnFailure() {
        for i in 0..<6 { add(Double(i) * 10, ms: 30) }
        XCTAssertEqual(evaluator.status, .level(.good))
        // One failure among ~6 samples is ≤ 20% loss: mixed.
        XCTAssertEqual(add(60, failure: .timeout), .level(.mixed))
        // A second failure in a row: offline.
        XCTAssertEqual(add(70, failure: .timeout), .level(.offline))
    }

    func testNoPathIsOfflineImmediately() {
        for i in 0..<6 { add(Double(i) * 10, ms: 30) }
        XCTAssertEqual(add(60, failure: .noPath), .level(.offline))
    }

    func testCaptivePortal() {
        for i in 0..<6 { add(Double(i) * 10, ms: 30) }
        XCTAssertEqual(add(60, failure: .captivePortal), .captivePortal)
        // Leaving the portal goes to poor first, like leaving offline.
        XCTAssertEqual(add(70, ms: 30), .level(.poor))
    }

    func testRecoversSlowlyOneLevelAtATime() {
        add(0, failure: .timeout)
        add(10, failure: .timeout)
        XCTAssertEqual(evaluator.status, .level(.offline))

        // Leaving offline goes straight to poor.
        XCTAssertEqual(add(20, ms: 30), .level(.poor))

        // t=0 and t=10 failures keep the raw level poor (2 of 7 lost) up to t=60.
        for time in stride(from: 30.0, through: 60.0, by: 10) {
            XCTAssertEqual(add(time, ms: 30), .level(.poor), "at \(time)")
        }
        // From t=70 the raw level is better; it must stay better for 30 s to climb to mixed...
        XCTAssertEqual(add(70, ms: 30), .level(.poor))
        XCTAssertEqual(add(80, ms: 30), .level(.poor))
        XCTAssertEqual(add(90, ms: 30), .level(.poor))
        XCTAssertEqual(add(100, ms: 30), .level(.mixed))
        // ...and another 30 s to climb to good.
        XCTAssertEqual(add(110, ms: 30), .level(.mixed))
        XCTAssertEqual(add(120, ms: 30), .level(.mixed))
        XCTAssertEqual(add(130, ms: 30), .level(.mixed))
        XCTAssertEqual(add(140, ms: 30), .level(.good))
    }

    func testRecoveryRestartsAfterSetback() {
        evaluator.configuration.window = 15
        evaluator.configuration.recoveryDuration = 20
        add(0, ms: 300)
        XCTAssertEqual(add(5, ms: 300), .level(.mixed))
        add(10, ms: 30)
        add(15, ms: 30)
        // Raw level turns good at t=20: the recovery timer starts.
        XCTAssertEqual(add(20, ms: 30), .level(.mixed))
        XCTAssertEqual(add(25, ms: 30), .level(.mixed))
        // A slow sample pushes p90 up (raw mixed) until it leaves the window at t=50.
        for time in stride(from: 30.0, through: 45.0, by: 5) {
            XCTAssertEqual(add(time, ms: time == 30 ? 900 : 30), .level(.mixed), "at \(time)")
        }
        // The timer restarted at t=50, so good only arrives 20 s later.
        for time in stride(from: 50.0, through: 65.0, by: 5) {
            XCTAssertEqual(add(time, ms: 30), .level(.mixed), "at \(time)")
        }
        XCTAssertEqual(add(70, ms: 30), .level(.good))
    }

    func testResetReturnsToMeasuring() {
        add(0, ms: 30)
        add(10, ms: 30)
        evaluator.reset()
        XCTAssertEqual(evaluator.status, .measuring)
    }

    func testOldSamplesOutsideWindowIgnored() {
        let raw = evaluator.rawLevel([
            .failure(at: t0, .timeout),
            .success(at: t0.addingTimeInterval(100), rtt: 0.02),
            .success(at: t0.addingTimeInterval(110), rtt: 0.02),
        ], now: t0.addingTimeInterval(110))
        XCTAssertEqual(raw, .good)
    }
}

final class StatisticsTests: XCTestCase {
    func testSummary() {
        let t0 = Date(timeIntervalSince1970: 0)
        let samples: [Sample] = [
            .success(at: t0, rtt: 0.010),
            .success(at: t0.addingTimeInterval(1), rtt: 0.030),
            .failure(at: t0.addingTimeInterval(2), .timeout),
            .success(at: t0.addingTimeInterval(3), rtt: 0.020),
        ]
        let summary = SampleSummary(samples)
        XCTAssertEqual(summary.count, 4)
        XCTAssertEqual(summary.successCount, 3)
        XCTAssertEqual(summary.loss, 0.25, accuracy: 1e-9)
        XCTAssertEqual(summary.medianRTT ?? 0, 0.020, accuracy: 1e-9)
        XCTAssertEqual(summary.minRTT, 0.010)
        XCTAssertEqual(summary.maxRTT, 0.030)
        XCTAssertEqual(summary.last?.rtt, 0.020)
    }

    func testEmptySummary() {
        let summary = SampleSummary([Sample]())
        XCTAssertEqual(summary.count, 0)
        XCTAssertEqual(summary.loss, 0)
        XCTAssertNil(summary.medianRTT)
    }

    func testPercentile() {
        XCTAssertEqual(SampleSummary.percentile(0.9, ofSorted: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) ?? 0, 9.1, accuracy: 1e-9)
        XCTAssertEqual(SampleSummary.percentile(0.5, ofSorted: [5]), 5)
        XCTAssertNil(SampleSummary.percentile(0.5, ofSorted: []))
    }

    func testHistoryRetention() {
        var history = SampleHistory(retention: 60)
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<20 {
            history.append(.success(at: t0.addingTimeInterval(Double(i) * 10), rtt: 0.01))
        }
        XCTAssertEqual(history.samples.count, 7) // t = 130...190
        XCTAssertEqual(history.samples(since: t0.addingTimeInterval(175)).count, 2)
    }
}

final class ProbingTests: XCTestCase {
    func testHTTPExpectationNoContent() {
        XCTAssertNil(HTTPExpectation.noContent.failure(forStatus: 204))
        XCTAssertEqual(HTTPExpectation.noContent.failure(forStatus: 200), .captivePortal)
        XCTAssertEqual(HTTPExpectation.noContent.failure(forStatus: 302), .captivePortal)
        XCTAssertEqual(HTTPExpectation.noContent.failure(forStatus: 503), .unexpectedStatus(503))
    }

    func testHTTPExpectationAnySuccess() {
        XCTAssertNil(HTTPExpectation.anySuccess.failure(forStatus: 200))
        XCTAssertNil(HTTPExpectation.anySuccess.failure(forStatus: 204))
        XCTAssertEqual(HTTPExpectation.anySuccess.failure(forStatus: 307), .captivePortal)
        XCTAssertEqual(HTTPExpectation.anySuccess.failure(forStatus: 404), .unexpectedStatus(404))
    }

    func testEchoRequestChecksumVerifies() {
        let packet = ICMPEcho.request(identifier: 0x1234, sequence: 7, payload: Array("hello".utf8))
        XCTAssertEqual(packet[0], 8)
        XCTAssertEqual(Array(packet[4..<8]), [0x12, 0x34, 0x00, 0x07])
        // Summing a packet including its own checksum yields zero.
        XCTAssertEqual(ICMPEcho.checksum(packet), 0)
    }

    func testChecksumKnownValue() {
        // Example from RFC 1071 section 3: words 0001 f203 f4f5 f6f7 sum to ddf2 (complement 220d).
        XCTAssertEqual(ICMPEcho.checksum([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]), 0x220d)
    }

    /// An echo reply as a server would send it, with a valid checksum.
    private func makeReply(identifier: UInt16, sequence: UInt16, payload: [UInt8]) -> [UInt8] {
        var reply = ICMPEcho.request(identifier: identifier, sequence: sequence, payload: payload)
        reply[0] = ICMPEcho.echoReplyType
        reply[2] = 0
        reply[3] = 0
        let sum = ICMPEcho.checksum(reply)
        reply[2] = UInt8(sum >> 8)
        reply[3] = UInt8(sum & 0xff)
        return reply
    }

    private func ipHeader(source: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 20)
        header[0] = 0x45
        header.replaceSubrange(12..<16, with: source)
        return header
    }

    func testParseReplyWithAndWithoutIPHeader() {
        let reply = makeReply(identifier: 0xabcd, sequence: 42, payload: [1, 2, 3])
        XCTAssertEqual(ICMPEcho.parseReply(reply),
                       ICMPEcho.Reply(identifier: 0xabcd, sequence: 42, payload: [1, 2, 3]))

        let parsed = ICMPEcho.parseReply(ipHeader(source: [8, 8, 4, 4]) + reply)
        XCTAssertEqual(parsed, ICMPEcho.Reply(identifier: 0xabcd, sequence: 42, payload: [1, 2, 3],
                                              source: 0x0808_0404))
    }

    func testParseIgnoresRequestsShortPacketsAndBadChecksums() {
        let request = ICMPEcho.request(identifier: 1, sequence: 1, payload: [])
        XCTAssertNil(ICMPEcho.parseReply(request))
        XCTAssertNil(ICMPEcho.parseReply([0, 0, 0]))
        var corrupt = makeReply(identifier: 1, sequence: 1, payload: [9, 9])
        corrupt[9] ^= 0xff
        XCTAssertNil(ICMPEcho.parseReply(corrupt))
    }

    func testReplyMatching() {
        let payload: [UInt8] = [1, 2, 3, 4]
        let google: UInt32 = 0x0808_0808
        func check(_ reply: ICMPEcho.Reply) -> Bool {
            ICMPEcho.reply(reply, matches: 7, sequence: 9, payload: payload, expectedSource: google)
        }
        XCTAssertTrue(check(.init(identifier: 7, sequence: 9, payload: payload, source: google)))
        XCTAssertTrue(check(.init(identifier: 7, sequence: 9, payload: payload, source: nil)))
        XCTAssertFalse(check(.init(identifier: 7, sequence: 9, payload: payload, source: 0x0A00_0001)),
                       "reply from another address")
        XCTAssertFalse(check(.init(identifier: 8, sequence: 9, payload: payload, source: google)))
        XCTAssertFalse(check(.init(identifier: 7, sequence: 10, payload: payload, source: google)))
        XCTAssertFalse(check(.init(identifier: 7, sequence: 9, payload: [1, 2, 3, 5], source: google)),
                       "forged reply without our random payload")
    }
}

final class MonitorSettingsTests: XCTestCase {
    func testDefaultsAndNormalization() {
        let store = UserDefaults(suiteName: "MonitorSettingsTests-\(UUID().uuidString)")!
        var settings = MonitorSettings(defaults: store)
        XCTAssertEqual(settings.mode, .ping)
        XCTAssertEqual(settings.pingHost, "8.8.8.8")
        XCTAssertEqual(settings.url, "https://connectivitycheck.gstatic.com/generate_204")
        XCTAssertEqual(settings.interval, 10)
        XCTAssertEqual(settings.timeout, 3)

        store.set(5.0, forKey: MonitorSettings.Key.interval)
        store.set(20.0, forKey: MonitorSettings.Key.timeout)
        store.set("  ", forKey: MonitorSettings.Key.pingHost)
        settings = MonitorSettings(defaults: store)
        XCTAssertEqual(settings.timeout, 5, "timeout is capped at the interval")
        XCTAssertEqual(settings.pingHost, "8.8.8.8")
        XCTAssertEqual(settings.makeEvaluatorConfiguration(interval: settings.interval).window, 60)
    }

    func testValuesAreClampedAtBothEnds() {
        let store = UserDefaults(suiteName: "MonitorSettingsTests-\(UUID().uuidString)")!
        store.set(1e9, forKey: MonitorSettings.Key.interval)
        store.set(1e9, forKey: MonitorSettings.Key.tetheredInterval)
        store.set(1e9, forKey: MonitorSettings.Key.timeout)
        store.set(1e9, forKey: MonitorSettings.Key.goodLatencyMs)
        store.set(1e9, forKey: MonitorSettings.Key.poorLatencyMs)
        store.set(1e9, forKey: MonitorSettings.Key.recoverySeconds)
        store.set(String(repeating: "a", count: 300), forKey: MonitorSettings.Key.pingHost)
        store.set("https://example.com/" + String(repeating: "a", count: 3000), forKey: MonitorSettings.Key.url)
        let settings = MonitorSettings(defaults: store)
        XCTAssertEqual(settings.interval, MonitorSettings.Limit.interval)
        XCTAssertEqual(settings.tetheredInterval, MonitorSettings.Limit.interval)
        XCTAssertEqual(settings.timeout, MonitorSettings.Limit.timeout)
        XCTAssertEqual(settings.goodLatencyMs, MonitorSettings.Limit.latencyMs)
        XCTAssertEqual(settings.poorLatencyMs, MonitorSettings.Limit.latencyMs)
        XCTAssertEqual(settings.recoverySeconds, MonitorSettings.Limit.recoverySeconds)
        XCTAssertEqual(settings.pingHost, MonitorSettings.defaultPingHost)
        XCTAssertEqual(settings.url, MonitorSettings.defaultURL)
    }

    func testURLValidation() {
        func problem(_ string: String) -> MonitorSettings.URLProblem? {
            if case .failure(let problem) = MonitorSettings.validateURL(string) { return problem }
            return nil
        }
        XCTAssertNil(problem(MonitorSettings.defaultURL))
        XCTAssertNil(problem("  https://example.com/health  "))
        XCTAssertNil(problem("http://captive.apple.com/hotspot-detect.html"))
        XCTAssertEqual(problem("http://example.com/"), .plainHTTPNotAllowed)
        XCTAssertEqual(problem("file:///etc/passwd"), .unsupportedScheme)
        XCTAssertEqual(problem("ftp://example.com/"), .unsupportedScheme)
        XCTAssertEqual(problem("javascript:alert(1)"), .unsupportedScheme)
        XCTAssertEqual(problem("https://"), .invalid)
        XCTAssertEqual(problem("not a url"), .invalid)
    }

    func testTetheredBackoff() {
        let store = UserDefaults(suiteName: "MonitorSettingsTests-\(UUID().uuidString)")!
        var settings = MonitorSettings(defaults: store)
        XCTAssertTrue(settings.tetheredBackoff)
        XCTAssertEqual(settings.probeInterval(onExpensiveNetwork: false), 10)
        XCTAssertEqual(settings.probeInterval(onExpensiveNetwork: true), 30)
        XCTAssertEqual(settings.scheduleDescription(onExpensiveNetwork: true), "Ping 8.8.8.8, every 30 s (tethered)")
        XCTAssertEqual(settings.scheduleDescription(onExpensiveNetwork: false), "Ping 8.8.8.8, every 10 s")
        // A longer interval means a longer evaluation window.
        XCTAssertEqual(settings.makeEvaluatorConfiguration(interval: 30).window, 180)

        // Never probes faster when tethered than normally.
        store.set(60.0, forKey: MonitorSettings.Key.interval)
        settings = MonitorSettings(defaults: store)
        XCTAssertEqual(settings.probeInterval(onExpensiveNetwork: true), 60)

        store.set(false, forKey: MonitorSettings.Key.tetheredBackoff)
        settings = MonitorSettings(defaults: store)
        XCTAssertEqual(settings.probeInterval(onExpensiveNetwork: true), 60)
        XCTAssertEqual(settings.scheduleDescription(onExpensiveNetwork: true), "Ping 8.8.8.8, every 60 s")
    }
}
