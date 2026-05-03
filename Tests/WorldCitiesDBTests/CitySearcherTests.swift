import XCTest
@testable import WorldCitiesDB

private struct TestCity: SearchableCity, Equatable {
    let id: String
    let name: String
    let asciiName: String
    let alternateNames: [String]
    let alternateAsciiNames: [String]

    func matchPrimaryNames(_ fastMatcher: (String) -> Bool, _ foldMatcher: (String) -> Bool) -> Bool {
        match([name, asciiName], fastMatcher, foldMatcher)
    }

    func matchAlternateNames(_ fastMatcher: (String) -> Bool, _ foldMatcher: (String) -> Bool) -> Bool {
        match(alternateNames + alternateAsciiNames, fastMatcher, foldMatcher)
    }

    private func match(
        _ fields: [String],
        _ fastMatcher: (String) -> Bool,
        _ foldMatcher: (String) -> Bool
    ) -> Bool {
        for field in fields {
            if CasefoldingCache.stringNeedsFoldLookup(field) {
                if foldMatcher(field) { return true }
            } else if fastMatcher(field) {
                return true
            }
        }
        return false
    }
}

final class CitySearcherTests: XCTestCase {
    func testProgressiveSearchNarrowingAcrossSingleCharacterPrefix() {
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
        let cities = [
            TestCity(id: "alt-high", name: "Alpha", asciiName: "Alpha", alternateNames: [], alternateAsciiNames: ["jil"]),
            TestCity(id: "primary-low", name: "Jilburg", asciiName: "Jilburg", alternateNames: [], alternateAsciiNames: []),
        ]

        let results = CitySearcher(cities: cities).search(query: "jil", limit: -1)
        XCTAssertEqual(results.map(\.id), ["primary-low", "alt-high"])
    }

    func testLimitedSearchStillPrioritizesPrimaryMatches() {
        let cities = [
            TestCity(id: "alt-high", name: "Alpha", asciiName: "Alpha", alternateNames: [], alternateAsciiNames: ["jil"]),
            TestCity(id: "primary-low", name: "Jilburg", asciiName: "Jilburg", alternateNames: [], alternateAsciiNames: []),
        ]

        let results = CitySearcher(cities: cities).search(query: "jil", limit: 1)
        XCTAssertEqual(results.map(\.id), ["primary-low"])
    }

    func testSearchWithZeroLimitReturnsEmpty() {
        let cities = [
            TestCity(id: "tokyo", name: "Tokyo", asciiName: "Tokyo", alternateNames: [], alternateAsciiNames: []),
        ]

        let results = CitySearcher(cities: cities).search(query: "tok", limit: 0)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchRespectsLimitWhenPrimaryMatchesExceedLimit() {
        let cities = (0..<40).map {
            TestCity(
                id: "tok-\($0)",
                name: "Tokyo \($0)",
                asciiName: "Tokyo \($0)",
                alternateNames: [],
                alternateAsciiNames: []
            )
        }

        let results = CitySearcher(cities: cities).search(query: "tok", limit: 5)
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results.map(\.id), ["tok-0", "tok-1", "tok-2", "tok-3", "tok-4"])
    }

    func testProgressiveSearchCanReclassifyFromPrimaryToAlternate() {
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

    func testUnicodeFoldExpansionMatchesLigature() {
        let cities = [
            TestCity(id: "ligature", name: "ﬃtown", asciiName: "ffitown", alternateNames: [], alternateAsciiNames: []),
        ]

        let results = CitySearcher(cities: cities).search(query: "ffi", limit: -1)
        XCTAssertEqual(results.map(\.id), ["ligature"])
    }

    // MARK: - Non-ASCII Index Tests

    func testPureNonASCIIQueryUsesUTF8Index() {
        let cities = [
            TestCity(id: "tokyo", name: "東京", asciiName: "Tokyo", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "beijing", name: "北京", asciiName: "Beijing", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "kyoto", name: "京都", asciiName: "Kyoto", alternateNames: [], alternateAsciiNames: []),
        ]

        let results = CitySearcher(cities: cities).search(query: "京", limit: -1)
        // All three contain 京
        XCTAssertEqual(results.map(\.id).sorted(), ["beijing", "kyoto", "tokyo"])
    }

    func testPureNonASCIIQueryFiltersByIntersection() {
        let cities = [
            TestCity(id: "tokyo", name: "東京", asciiName: "Tokyo", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "beijing", name: "北京", asciiName: "Beijing", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "kyoto", name: "京都", asciiName: "Kyoto", alternateNames: [], alternateAsciiNames: []),
        ]

        // "東京" requires both 東 and 京
        let results = CitySearcher(cities: cities).search(query: "東京", limit: -1)
        XCTAssertEqual(results.map(\.id), ["tokyo"])
    }

    func testMixedASCIIAndNonASCIIQuery() {
        let cities = [
            TestCity(id: "munchen", name: "München", asciiName: "Munchen", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "zurich", name: "Zürich", asciiName: "Zurich", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "berlin", name: "Berlin", asciiName: "Berlin", alternateNames: [], alternateAsciiNames: []),
        ]

        let results = CitySearcher(cities: cities).search(query: "münch", limit: -1)
        XCTAssertEqual(results.map(\.id), ["munchen"])
    }

    func testFoldedASCIIQueryMatchesASCIIOnlyField() {
        let cities = [
            TestCity(id: "ascii-only", name: "Plain", asciiName: "Munchen", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "other", name: "Other", asciiName: "Other", alternateNames: [], alternateAsciiNames: []),
        ]

        let artifacts = SearchArtifacts(cities: cities)
        let searcher = CitySearcher(
            cities: cities,
            casefoldingCache: artifacts.casefoldingCache,
            searchIndex: artifacts.searchIndex,
            packedSearchFields: artifacts.packedSearchFields
        )

        XCTAssertEqual(searcher.search(query: "mün", limit: -1).map(\.id), ["ascii-only"])
    }

    func testPureNonASCIIQueryWithPrebuiltArtifactsDoesNotMatchASCIIOnlyCity() {
        let cities = [
            TestCity(id: "ascii-only", name: "Kyoto", asciiName: "Kyoto", alternateNames: [], alternateAsciiNames: ["Tokyo Metropolis"]),
            TestCity(id: "utf8-match", name: "京都", asciiName: "Kyoto", alternateNames: [], alternateAsciiNames: []),
        ]

        let artifacts = SearchArtifacts(cities: cities)
        let searcher = CitySearcher(
            cities: cities,
            casefoldingCache: artifacts.casefoldingCache,
            searchIndex: artifacts.searchIndex,
            packedSearchFields: artifacts.packedSearchFields
        )

        XCTAssertEqual(searcher.search(query: "京", limit: -1).map(\.id), ["utf8-match"])
    }

    func testProgressiveSearchWithNonASCII() {
        let cities = [
            TestCity(id: "tokyo", name: "東京", asciiName: "Tokyo", alternateNames: ["東京都"], alternateAsciiNames: []),
            TestCity(id: "beijing", name: "北京", asciiName: "Beijing", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "kyoto", name: "京都", asciiName: "Kyoto", alternateNames: [], alternateAsciiNames: []),
        ]

        let ctx = CitySearcher(cities: cities).newSearch()
        ctx.update(query: "京")
        XCTAssertEqual(ctx.results(limit: -1).count, 3) // All contain 京

        ctx.update(query: "京都")
        // "京都" as substring: kyoto has name "京都", tokyo has alternate "東京都" which contains "京都"
        let results = ctx.results(limit: -1).map(\.id)
        XCTAssertTrue(results.contains("kyoto"))
    }

    func testNonASCIICharNotInIndexReturnsEmpty() {
        let cities = [
            TestCity(id: "berlin", name: "Berlin", asciiName: "Berlin", alternateNames: [], alternateAsciiNames: []),
        ]

        let results = CitySearcher(cities: cities).search(query: "京", limit: -1)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchArtifactsRoundTripProducesEquivalentResults() throws {
        let cities = [
            TestCity(id: "tokyo", name: "東京", asciiName: "Tokyo", alternateNames: ["東京都"], alternateAsciiNames: ["Tokyo Metropolis"]),
            TestCity(id: "munchen", name: "München", asciiName: "Munchen", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "beijing", name: "北京", asciiName: "Beijing", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "eszett", name: "ẞeta", asciiName: "Beta", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "ligature", name: "ﬃtown", asciiName: "LigatureTown", alternateNames: [], alternateAsciiNames: []),
        ]

        let base = CitySearcher(cities: cities)
        let artifacts = SearchArtifacts(cities: cities)
        let encoded = artifacts.serializedData()
        let decoded = try SearchArtifacts(serializedData: encoded)
        let prebuilt = CitySearcher(
            cities: cities,
            casefoldingCache: decoded.casefoldingCache,
            searchIndex: decoded.searchIndex,
            packedSearchFields: decoded.packedSearchFields
        )

        for query in ["tok", "東京", "mün", "ße", "ffi", "京", "beta"] {
            let lhs = base.search(query: query, limit: -1).map(\.id)
            let rhs = prebuilt.search(query: query, limit: -1).map(\.id)
            XCTAssertEqual(lhs, rhs, "Mismatch for query '\(query)'")
        }
    }

    func testPrebuiltArtifactsWithMismatchedCityCountFallsBackToFullScan() {
        let small = [
            TestCity(id: "small", name: "Smalltown", asciiName: "Smalltown", alternateNames: [], alternateAsciiNames: []),
        ]
        let large = [
            TestCity(id: "tokyo", name: "Tokyo", asciiName: "Tokyo", alternateNames: [], alternateAsciiNames: []),
            TestCity(id: "toronto", name: "Toronto", asciiName: "Toronto", alternateNames: [], alternateAsciiNames: []),
        ]

        let artifacts = SearchArtifacts(cities: small)
        let withMismatchedArtifacts = CitySearcher(
            cities: large,
            casefoldingCache: artifacts.casefoldingCache,
            searchIndex: artifacts.searchIndex,
            packedSearchFields: artifacts.packedSearchFields
        )
        let baseline = CitySearcher(cities: large)
        XCTAssertEqual(
            withMismatchedArtifacts.search(query: "to", limit: -1).map(\.id),
            baseline.search(query: "to", limit: -1).map(\.id)
        )
    }

    func testWorldCitiesDBDecodesCityDatabaseFile() throws {
        let city = makeCity(
            geonameId: 42,
            name: "Testville",
            alternateNames: ["Téstvillé"],
            alternateAsciiNames: ["Testvile"],
            admin1Name: "New York"
        )

        let encoded = try makeCityDatabase(cities: [city])
        let db = try WorldCitiesDB<City>(data: encoded.data)
        XCTAssertEqual(db.count, 1)
        XCTAssertEqual(db.cities.first?.name, "Testville")
        XCTAssertEqual(db.cities.first?.countryCode, "US")
        XCTAssertEqual(db.metadata.cityCount, 1)
        XCTAssertEqual(db.metadata.cityDataFingerprint, encoded.metadata.cityDataFingerprint)
        XCTAssertEqual(db.searchIndex.cityCount, 1)
        XCTAssertEqual(db.packedSearchFields.cityCount, 1)
    }

    func testWorldCitiesDBRejectsCorruptedCityDatabasePayload() throws {
        let city = makeCity(geonameId: 42, name: "Testville")
        var fileData = try makeCityDatabase(cities: [city]).data
        // Corrupt the stored payload checksum in the file header.
        fileData[20] ^= 0x01

        XCTAssertThrowsError(try WorldCitiesDB<City>(data: fileData))
    }

    func testWorldCitiesDBLoadsBundledSearchArtifacts() throws {
        let cities = [
            makeCity(geonameId: 1, name: "Tokyo", alternateNames: ["東京"]),
            makeCity(geonameId: 2, name: "Berlin"),
        ]
        let encoded = try makeCityDatabase(cities: cities)
        let db = try WorldCitiesDB<City>(data: encoded.data)
        let searcher = CitySearcher(
            cities: db.cities,
            casefoldingCache: db.casefoldingCache,
            searchIndex: db.searchIndex,
            packedSearchFields: db.packedSearchFields
        )

        XCTAssertEqual(db.searchIndex.cityCount, cities.count)
        XCTAssertEqual(db.packedSearchFields.cityCount, cities.count)
        XCTAssertEqual(searcher.search(query: "京", limit: -1).map(\.geonameId), [1])
    }

    func testWorldCitiesDBRejectsCorruptedSearchArtifactPayload() throws {
        let cities = [makeCity(geonameId: 1, name: "Tokyo")]
        var fileData = try makeCityDatabase(cities: cities).data
        // Corrupt the stored search payload checksum in the file header.
        fileData[32] ^= 0x01

        XCTAssertThrowsError(try WorldCitiesDB<City>(data: fileData))
    }
}

private func makeCity(
    geonameId: Int,
    name: String,
    asciiName: String? = nil,
    alternateNames: [String] = [],
    alternateAsciiNames: [String] = [],
    admin1Name: String? = nil
) -> City {
    City(
        geonameId: geonameId,
        name: name,
        asciiName: asciiName ?? name,
        alternateNames: alternateNames,
        alternateAsciiNames: alternateAsciiNames,
        latitude: 12.34,
        longitude: 56.78,
        featureClass: "P",
        featureCode: "PPL",
        countryCode: "US",
        cc2: [],
        admin1Code: "NY",
        admin1Name: admin1Name,
        admin2Code: nil,
        admin2Name: nil,
        admin3Code: nil,
        admin4Code: nil,
        population: 123_456,
        elevation: nil,
        dem: nil,
        timezone: "America/New_York",
        modificationDate: nil
    )
}

private func makeCityDatabase(cities: [City]) throws -> EncodedCityDatabase {
    try CityDatabaseFile.serializedData(cities: cities, metadata: CityDatabaseMetadata(
        schemaVersion: CityDatabaseFile.currentSchemaVersion,
        generatedAt: "2026-05-02T00:00:00Z",
        sourceName: "Unit test",
        sourceURLs: [],
        cityCount: cities.count,
        sortOrder: "populationDescending",
        cityDataFingerprint: "",
        searchDataFingerprint: "",
        searchSchemaID: CityDatabaseFile.defaultSearchSchemaID,
        foldOptionsVersion: CityDatabaseFile.currentFoldOptionsVersion,
        includesAdmin1Names: true,
        includesAdmin2Names: true
    ), searchArtifacts: SearchArtifacts(cities: cities))
}
