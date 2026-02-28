import XCTest
@testable import WorldCitiesDB

private struct TestCity: SearchableCity, Equatable, Sendable {
    let id: String
    let name: String
    let asciiName: String
    let alternateNames: [String]
    let alternateAsciiNames: [String]

    func matchesASCII(_ test: (String) -> Bool) -> Bool {
        matchesPrimaryASCII(test) || matchesAlternateASCII(test)
    }

    func matchesUTF8(_ test: (String) -> Bool) -> Bool {
        matchesPrimaryUTF8(test) || matchesAlternateUTF8(test)
    }

    func matchesPrimaryASCII(_ test: (String) -> Bool) -> Bool {
        test(asciiName)
    }

    func matchesAlternateASCII(_ test: (String) -> Bool) -> Bool {
        alternateAsciiNames.contains(where: test)
    }

    func matchesPrimaryUTF8(_ test: (String) -> Bool) -> Bool {
        test(name)
    }

    func matchesAlternateUTF8(_ test: (String) -> Bool) -> Bool {
        alternateNames.contains(where: test)
    }
}

final class CitySearcherTests: XCTestCase {
    func testProgressiveSearchNarrowingAcrossSingleCharacterPrefix() {
        // Input order is population-descending.
        let cities = [
            TestCity(id: "jakarta", name: "Jakarta", asciiName: "Jakarta", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "jilin", name: "Jilin", asciiName: "Jilin", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "jihlava", name: "Jihlava", asciiName: "Jihlava", alternateNames: [], alternateAsciiNames: []),
        ]

        let ctx = CitySearcher(cities: cities).newSearch()
        ctx.update(query: "j")
        XCTAssertEqual(ctx.results(limit: 1).map(\.id), ["jakarta"])

        ctx.update(query: "ji")
        XCTAssertEqual(ctx.results(limit: -1).map(\.id), ["jilin", "jihlava"])

        ctx.update(query: "jil")
        XCTAssertEqual(ctx.results(limit: -1).map(\.id), ["jilin"])
    }

    func testPrimaryMatchesAreRankedBeforeAlternateMatches() {
        // First city has higher population but only alternate-name match.
        let cities = [
            TestCity(id: "alt-high", name: "Alpha", asciiName: "Alpha", alternateNames: [], alternateAsciiNames: ["jil"]),
            TestCity(id: "primary-low", name: "Jilburg", asciiName: "Jilburg", alternateNames: [], alternateAsciiNames: []),
        ]

        let results = CitySearcher(cities: cities).search(query: "jil", limit: -1)
        XCTAssertEqual(results.map(\.id), ["primary-low", "alt-high"])
    }

    func testProgressiveSearchCanReclassifyFromPrimaryToAlternate() {
        // "switch" starts as a primary match for "a", then only alternate for "ab".
        let cities = [
            TestCity(id: "switch", name: "Aaa", asciiName: "Aaa", alternateNames: [], alternateAsciiNames: ["ab"]),
            TestCity(id: "primary", name: "Abbot", asciiName: "Abbot", alternateNames: [], alternateAsciiNames: []),
        ]

        let ctx = CitySearcher(cities: cities).newSearch()
        ctx.update(query: "a")
        XCTAssertEqual(ctx.results(limit: -1).map(\.id), ["switch", "primary"])

        ctx.update(query: "ab")
        XCTAssertEqual(ctx.results(limit: -1).map(\.id), ["primary", "switch"])
    }

    func testUnicodeCaseInsensitiveMatchForCapitalSharpS() {
        let cities = [
            TestCity(id: "eszett", name: "ẞeta", asciiName: "Beta", alternateNames: [], alternateAsciiNames: []),
        ]

        let results = CitySearcher(cities: cities).search(query: "ße", limit: -1)
        XCTAssertEqual(results.map(\.id), ["eszett"])
    }

    func testUnicodeCaseInsensitiveMatchUsesThreePointerPathForSimpleCaseMapping() {
        let cities = [
            TestCity(id: "athens-upper", name: "ΑΘΉΝΑ", asciiName: "Athina", alternateNames: [], alternateAsciiNames: []),
        ]

        let results = CitySearcher(cities: cities).search(query: "θή", limit: -1)
        XCTAssertEqual(results.map(\.id), ["athens-upper"])
    }
}
