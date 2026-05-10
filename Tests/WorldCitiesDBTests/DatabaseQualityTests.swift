import XCTest
@testable import WorldCitiesDB

final class DatabaseQualityTests: XCTestCase {
    func testBundledDatabaseExcludesZeroPopulationRows() throws {
        let db = try WorldCitiesDB<City>()

        XCTAssertFalse(db.cities.contains { $0.population == 0 })
    }

    func testHanoiZeroPopulationDuplicateIsExcluded() throws {
        let db = try WorldCitiesDB<City>()

        let hanoiRows = db.cities.filter {
            $0.countryCode == "VN"
                && $0.admin1Code == "01"
                && $0.asciiName == "Hanoi"
        }

        XCTAssertEqual(hanoiRows.count, 1)
        XCTAssertEqual(hanoiRows.first?.geonameId, 1_581_130)
        XCTAssertGreaterThan(hanoiRows.first?.population ?? 0, 0)
        XCTAssertFalse(hanoiRows.contains { $0.geonameId == 8_554_466 })
    }
}
