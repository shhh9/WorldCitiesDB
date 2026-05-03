import Foundation
import WorldCitiesDB

// MARK: - Custom lightweight city type (from plan example)

struct WorldClockCity: CityRepresentable, SearchableCity {
    private static let nameUsesFoldMatcher: UInt8 = 1 << 0
    private static let asciiNameUsesFoldMatcher: UInt8 = 1 << 1
    private static let alternateNamesUsesFoldMatcher: UInt8 = 1 << 2
    private static let alternateAsciiNamesUsesFoldMatcher: UInt8 = 1 << 3

    let name: String                    // UTF-8
    let asciiName: String               // ASCII
    let alternateNames: String          // UTF-8, \t-joined
    let alternateAsciiNames: String     // ASCII, \t-joined
    let timezone: String
    let countryCode: String
    let admin1Code: String?
    let admin1Name: String?
    private let matcherBits: UInt8

    init(from fields: borrowing CityFields) {
        let name = fields.name()
        let asciiName = fields.asciiName()
        let alternateNames = fields.alternateNames().joined(separator: "\t")
        let alternateAsciiNames = fields.alternateAsciiNames().joined(separator: "\t")

        var matcherBits: UInt8 = 0
        if CasefoldingCache.stringNeedsFoldLookup(name) {
            matcherBits |= Self.nameUsesFoldMatcher
        }
        if CasefoldingCache.stringNeedsFoldLookup(asciiName) {
            matcherBits |= Self.asciiNameUsesFoldMatcher
        }
        if CasefoldingCache.stringNeedsFoldLookup(alternateNames) {
            matcherBits |= Self.alternateNamesUsesFoldMatcher
        }
        if CasefoldingCache.stringNeedsFoldLookup(alternateAsciiNames) {
            matcherBits |= Self.alternateAsciiNamesUsesFoldMatcher
        }

        self.name = name
        self.asciiName = asciiName
        self.alternateNames = alternateNames
        self.alternateAsciiNames = alternateAsciiNames
        self.timezone = fields.timezone() ?? ""
        self.countryCode = fields.countryCode()
        self.admin1Code = fields.admin1Code()
        self.admin1Name = fields.admin1Name()
        self.matcherBits = matcherBits
    }

    func matchPrimaryNames(_ fastMatcher: (String) -> Bool, _ foldMatcher: (String) -> Bool) -> Bool {
        match(name, Self.nameUsesFoldMatcher, fastMatcher, foldMatcher)
            || match(asciiName, Self.asciiNameUsesFoldMatcher, fastMatcher, foldMatcher)
    }

    func matchAlternateNames(_ fastMatcher: (String) -> Bool, _ foldMatcher: (String) -> Bool) -> Bool {
        (!alternateNames.isEmpty && match(alternateNames, Self.alternateNamesUsesFoldMatcher, fastMatcher, foldMatcher))
            || (!alternateAsciiNames.isEmpty
                && match(alternateAsciiNames, Self.alternateAsciiNamesUsesFoldMatcher, fastMatcher, foldMatcher))
    }

    @inline(__always)
    private func match(
        _ field: String,
        _ usesFoldBit: UInt8,
        _ fastMatcher: (String) -> Bool,
        _ foldMatcher: (String) -> Bool
    ) -> Bool {
        if matcherBits & usesFoldBit != 0 {
            return foldMatcher(field)
        }
        return fastMatcher(field)
    }
}

// MARK: - Demo


@main
struct Demo {
    static func main() throws {
        // =============================================
        // Part 1: Full City (all fields)
        // =============================================
        print("========== City (all fields) ==========\n")

        var start = CFAbsoluteTimeGetCurrent()
        let db = try WorldCitiesDB<City>()
        let cityLoadTime = CFAbsoluteTimeGetCurrent() - start
        print("Loaded \(db.count) cities in \(String(format: "%.3f", cityLoadTime))s")

        start = CFAbsoluteTimeGetCurrent()
        let searcher = CitySearcher(
            cities: db.cities,
            casefoldingCache: db.casefoldingCache,
            searchIndex: db.searchIndex,
            packedSearchFields: db.packedSearchFields
        )
        let buildTime = CFAbsoluteTimeGetCurrent() - start
        print("Initialized index in \(String(format: "%.3f", buildTime))s")

        let testQueries = ["x", "yo", "tok", "beij", "paris", "new york", "京", "münchen"]
        print("\n=== Search Performance ===")
        print("Query         Time        Results")
        print(String(repeating: "-", count: 45))

        for query in testQueries {
            start = CFAbsoluteTimeGetCurrent()
            let results = searcher.search(query: query, limit: -1)
            let time = CFAbsoluteTimeGetCurrent() - start
            let q = query.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("\(q)  \(String(format: "%8.3fms", time * 1000))  \(String(format: "%5d", results.count))")
        }

        // Progressive search
        print("\n=== Progressive search ===")
        let search = searcher.newSearch()
        for query in ["t", "to", "tok", "toky", "tokyo"] {
            start = CFAbsoluteTimeGetCurrent()
            search.update(query: query)
            let all = search.results(limit: -1)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let names = all.prefix(5).map { "\($0.name) (\($0.countryCode))" }.joined(separator: ", ")
            print("  \"\(query)\" → \(all.count) total: \(names)  (\(String(format: "%.3f", elapsed * 1000))ms)")
        }

        // =============================================
        // Part 2: WorldClockCity (minimal fields)
        // =============================================
        print("\n\n========== WorldClockCity (minimal fields) ==========\n")

        start = CFAbsoluteTimeGetCurrent()
        let clockDB = try WorldCitiesDB<WorldClockCity>()
        let clockLoadTime = CFAbsoluteTimeGetCurrent() - start
        print("Loaded \(clockDB.count) cities in \(String(format: "%.3f", clockLoadTime))s")

        start = CFAbsoluteTimeGetCurrent()
        let clockSearcher = CitySearcher(
            cities: clockDB.cities,
            casefoldingCache: clockDB.casefoldingCache,
            searchIndex: clockDB.searchIndex,
            packedSearchFields: clockDB.packedSearchFields
        )
        let clockBuildTime = CFAbsoluteTimeGetCurrent() - start
        print("Initialized index in \(String(format: "%.3f", clockBuildTime))s")

        print("\n=== Search Performance ===")
        print("Query         Time        Results")
        print(String(repeating: "-", count: 45))

        for query in testQueries {
            start = CFAbsoluteTimeGetCurrent()
            let results = clockSearcher.search(query: query, limit: -1)
            let time = CFAbsoluteTimeGetCurrent() - start
            let q = query.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("\(q)  \(String(format: "%8.3fms", time * 1000))  \(String(format: "%5d", results.count))")
        }

        // Progressive search
        print("\n=== Progressive search ===")
        let clockSearch = clockSearcher.newSearch()
        for query in ["t", "to", "tok", "toky", "tokyo"] {
            start = CFAbsoluteTimeGetCurrent()
            clockSearch.update(query: query)
            let all = clockSearch.results(limit: -1)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let names = all.prefix(5).map { "\($0.name) (\($0.countryCode)) [\($0.timezone)]" }.joined(separator: ", ")
            print("  \"\(query)\" → \(all.count) total: \(names)  (\(String(format: "%.3f", elapsed * 1000))ms)")
        }

        // Show sample results
        print("\n=== Top 5 results for \"new york\" ===")
        for city in clockSearcher.search(query: "new york", limit: 5) {
            print("  \(city.name) (\(city.countryCode)) — \(city.timezone), admin1: \(city.admin1Name ?? "nil")")
        }

        // =============================================
        // Part 3: Memory
        // =============================================
        print("\n\n========== Memory ==========")
        let citySize = MemoryLayout<City>.stride
        let clockSize = MemoryLayout<WorldClockCity>.stride
        print("City stride:           \(citySize) bytes × \(db.count) = \(citySize * db.count / 1024 / 1024) MB (shallow)")
        print("WorldClockCity stride: \(clockSize) bytes × \(clockDB.count) = \(clockSize * clockDB.count / 1024 / 1024) MB (shallow)")
        let foldTableCount = searcher.casefoldingCache?.entryCount ?? 0
        let foldTableBytes = foldTableCount * MemoryLayout<FoldEntry>.stride
        print("Fold table:            \(foldTableCount) entries × \(MemoryLayout<FoldEntry>.stride)B = \(foldTableBytes / 1024) KB")

        let (asciiBytes, nonAsciiBytes, nonAsciiCount) = searcher.searchIndex?.memorySummary() ?? (0, 0, 0)
        print("Index ASCII:           \(asciiBytes / 1024) KB")
        print("Index non-ASCII:       \(nonAsciiBytes / 1024) KB (\(nonAsciiCount) scalars)")
        print("Index total:           \((asciiBytes + nonAsciiBytes) / 1024) KB")

    }
}
