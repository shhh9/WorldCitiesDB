import Foundation
import WorldCitiesDB

// MARK: - Custom lightweight city type (from plan example)

struct WorldClockCity: CityRepresentable, SearchableCity {
    let name: String
    let asciiName: String
    let alternateNames: String        // UTF-8, \t-joined (substring search)
    let alternateAsciiNames: String   // ASCII, \t-joined (case-insensitive search)
    let timezone: String
    let countryCode: String
    let admin1Code: String?
    let admin1Name: String?

    init(from fields: borrowing CityFields) {
        self.name = fields.name()
        self.asciiName = fields.asciiName()
        self.alternateNames = fields.alternateNames().joined(separator: "\t")
        self.alternateAsciiNames = fields.alternateAsciiNames().joined(separator: "\t")
        self.timezone = fields.timezone() ?? ""
        self.countryCode = fields.countryCode()
        self.admin1Code = fields.admin1Code()
        self.admin1Name = fields.admin1Name()
    }

    func matchesPrimaryField(_ test: (String) -> Bool) -> Bool {
        test(asciiName) || test(name)
    }

    func matchesAlternateField(_ test: (String) -> Bool) -> Bool {
        test(alternateAsciiNames) || test(alternateNames)
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

        let searcher = CitySearcher(cities: db.cities)

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

        let clockSearcher = CitySearcher(cities: clockDB.cities)

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
        // Part 3: Memory comparison
        // =============================================
        print("\n\n========== Memory Comparison ==========")
        let citySize = MemoryLayout<City>.stride
        let clockSize = MemoryLayout<WorldClockCity>.stride
        let bitmapBytes = 36 * ((db.count + 63) / 64) * 8
        print("City stride:           \(citySize) bytes × \(db.count) = \(citySize * db.count / 1024 / 1024) MB (shallow)")
        print("WorldClockCity stride: \(clockSize) bytes × \(clockDB.count) = \(clockSize * clockDB.count / 1024 / 1024) MB (shallow)")
        print("Bitmap index:          \(bitmapBytes) bytes (\(bitmapBytes / 1024) KB)")
    }
}
