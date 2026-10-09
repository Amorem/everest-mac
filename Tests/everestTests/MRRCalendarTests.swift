import XCTest
@testable import everest

/// MRRCalendar keys: the API payload, money on a 102 px key, the rings.
final class MRRCalendarTests: XCTestCase {
    /// Shape of `GET /api/public/v1/metrics` (extra fields are ignored).
    static let payload = #"""
    {"currency":"EUR","generatedAt":"2026-10-09T12:00:00.000Z","today":"2026-10-09",
     "mrr":4210.5,"arr":50526,"activeSubscriptions":87,
     "revenue":{"today":120,"last30Days":5230.4,"daily":[{"date":"2026-10-08","value":300},{"date":"2026-10-09","value":120}]},
     "oneTimeSales":{"last30Days":800},
     "commits":{"available":true,"today":6,"last30Days":140,"maxDaily":12,"daily":[{"date":"2026-10-09","count":6}]},
     "trends":{"mrr":12.5,"revenue":-20}}
    """#

    func testPayloadDecodes() throws {
        let m = try JSONDecoder().decode(MRRCalendar.Metrics.self, from: Data(Self.payload.utf8))
        XCTAssertEqual(m.mrr, 4210.5)
        XCTAssertEqual(m.commits.today, 6)
        XCTAssertEqual(m.revenue.daily.count, 2)
    }

    func testCompactMoney() {
        XCTAssertEqual(MRRCalendar.compactMoney(980, currency: "USD"), "$980")
        XCTAssertEqual(MRRCalendar.compactMoney(4210.5, currency: "EUR"), "€4.2k")
        XCTAssertEqual(MRRCalendar.compactMoney(4000, currency: "EUR"), "€4k")
        XCTAssertEqual(MRRCalendar.compactMoney(52_300, currency: "GBP"), "£52k")
        XCTAssertEqual(MRRCalendar.compactMoney(1_250_000, currency: "EUR"), "€1.2M")
        XCTAssertEqual(MRRCalendar.compactMoney(15, currency: "SEK"), "SEK 15")
    }

    func testReadings() throws {
        let m = try JSONDecoder().decode(MRRCalendar.Metrics.self, from: Data(Self.payload.utf8))
        let mrr = LiveMetric.mrrCalendarReading(.mrr, m)
        XCTAssertEqual(mrr.text, "€4.2k")
        XCTAssertEqual(mrr.fraction, 0.5625, accuracy: 0.0001, "+12.5 % → just over half a ring")
        let today = LiveMetric.mrrCalendarReading(.revenueToday, m)
        XCTAssertEqual(today.text, "€120")
        XCTAssertEqual(today.fraction, 0.4, accuracy: 0.0001, "120 of the best day's 300")
        XCTAssertEqual(LiveMetric.mrrCalendarReading(.revenue30Days, m).fraction, 0.4, accuracy: 0.0001, "−20 %")
        let commits = LiveMetric.mrrCalendarReading(.commitsToday, m)
        XCTAssertEqual(commits.text, "6")
        XCTAssertEqual(commits.fraction, 0.5, accuracy: 0.0001)
    }
}
