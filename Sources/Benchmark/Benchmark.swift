import Darwin
import Foundation
import WorldCitiesDB

@main
struct Benchmark {
    private enum Mode: CaseIterable {
        case none, casefold, searchIndex, both

        var usesCasefoldCache: Bool { self == .casefold || self == .both }
        var usesSearchIndex: Bool { self == .searchIndex || self == .both }

        var label: String {
            switch self {
            case .none: "No indexes"
            case .casefold: "Casefold only"
            case .searchIndex: "Search index only"
            case .both: "Casefold + Search"
            }
        }

        var shortLabel: String {
            switch self {
            case .none: "noindex"
            case .casefold: "casefold"
            case .searchIndex: "search"
            case .both: "both"
            }
        }
    }

    private static let limits = [-1, 100, 50, 20]
    private static let queries = [
        "a", "an", "new", "san", "city",
        "to", "tok", "tokyo", "mün", "mun",
        "são", "rio", "los", "paris", "york",
        "京", "東京", "北京", "ß", "ffi",
    ]

    private struct Result {
        let mode: Mode
        let limit: Int
        let totalNs: UInt64
        let checksum: UInt64
        let perQueryNs: [UInt64]
        let perQueryResults: [Int]
        let perQueryIds: [[Int]]  // geonameIds per query for correctness checks

        var totalMs: Double { Double(totalNs) / 1_000_000 }
    }

    static func main() throws {
        if CommandLine.arguments.contains("--fold-lookup") {
            FoldLookupBench.run()
            return
        }

        guard CommandLine.arguments.count == 1 else {
            fputs("Usage: Benchmark [--fold-lookup]\n", stderr)
            Darwin.exit(1)
        }

        print("WorldCitiesDB Search Benchmark")
        print("queries=\(queries.count), limits=\(limits), modes=\(Mode.allCases.count)")

        let (db, dbMs) = measure { try! loadDatabase() }
        let cities = db.cities
        print("loaded \(cities.count) cities in \(fmt(dbMs)) ms")

        let casefoldingCache = db.casefoldingCache
        let searchIndex = db.searchIndex
        let packedSearchFields = db.packedSearchFields
        print("casefold cache: entries=\(casefoldingCache.entryCount)"
            + " raw=\(casefoldingCache.rawTableBytes / 1024) KB"
            + " disp=\(casefoldingCache.displacementBytes / 1024) KB"
            + " bits=\(casefoldingCache.needsFoldBitsBytes / 1024) KB"
            + " total=\(casefoldingCache.totalBytes / 1024) KB")
        print()

        var results: [Result] = []
        for limit in limits {
            print("=== limit = \(limit) ===")
            let baseline = runSuite(mode: .none, cities: cities,
                                    casefoldingCache: casefoldingCache,
                                    searchIndex: searchIndex,
                                    packedSearchFields: packedSearchFields,
                                    limit: limit)
            results.append(baseline)
            print("  \(pad(baseline.mode.label, 24)) \(fmt(baseline.totalNs)) ms total")

            var mismatches = 0
            for mode in Mode.allCases where mode != .none {
                let r = runSuite(mode: mode, cities: cities,
                                 casefoldingCache: casefoldingCache,
                                 searchIndex: searchIndex,
                                 packedSearchFields: packedSearchFields,
                                 limit: limit)
                results.append(r)

                // Compare each query's results against the no-index baseline.
                for (qi, q) in queries.enumerated() {
                    let expected = baseline.perQueryIds[qi].sorted()
                    let actual = r.perQueryIds[qi].sorted()
                    if actual != expected {
                        mismatches += 1
                        let missing = Set(expected).subtracting(actual)
                        let extra = Set(actual).subtracting(expected)
                        print("  MISMATCH query=\"\(q)\" \(mode.shortLabel): "
                            + "expected \(expected.count) results, got \(actual.count)"
                            + " missing=\(Array(missing.prefix(5))) extra=\(Array(extra.prefix(5)))")
                        for gid in missing.prefix(3) {
                            if let city = cities.first(where: { $0.geonameId == gid }) {
                                print("    city \(gid): name=\"\(city.name)\" ascii=\"\(city.asciiName)\""
                                    + " altNames=\(city.alternateNames.prefix(5))")
                            }
                        }
                    }
                }
                print("  \(pad(r.mode.label, 24)) \(fmt(r.totalNs)) ms total")
            }
            if mismatches == 0 {
                print("  All modes agree on results.")
            }

            print("  Speedup vs no-index:")
            for r in results where r.limit == limit && r.mode != .none {
                print("    \(pad(r.mode.label, 24)) \(String(format: "%.1fx", baseline.totalMs / max(r.totalMs, 1e-6)))")
            }
            print()
        }

        printSummaryTable(results: results)

        // Prevent dead-code elimination of search results.
        _ = results.reduce(UInt64(0)) { $0 &+ $1.checksum }
    }

    // MARK: - Run

    private static func runSuite(
        mode: Mode, cities: [City],
        casefoldingCache: CasefoldingCache, searchIndex: SearchIndex, packedSearchFields: PackedSearchFields,
        limit: Int
    ) -> Result {
        let searcher = CitySearcher(
            cities: cities,
            casefoldingCache: mode.usesCasefoldCache ? casefoldingCache : nil,
            searchIndex: mode.usesSearchIndex ? searchIndex : nil,
            packedSearchFields: packedSearchFields
        )

        var checksum: UInt64 = 0
        var perNs = [UInt64](repeating: 0, count: queries.count)
        var perCount = [Int](repeating: 0, count: queries.count)
        var perIds = [[Int]](repeating: [], count: queries.count)

        let t0 = now()
        for (qi, q) in queries.enumerated() {
            let qs = now()
            let r = searcher.search(query: q, limit: limit)
            perNs[qi] = now() - qs
            perCount[qi] = r.count
            perIds[qi] = r.map(\.geonameId)
            checksum &+= UInt64(r.count)
            if let first = r.first { checksum &+= UInt64(truncatingIfNeeded: first.geonameId) }
        }

        return Result(mode: mode, limit: limit, totalNs: now() - t0,
                       checksum: checksum, perQueryNs: perNs, perQueryResults: perCount,
                       perQueryIds: perIds)
    }

    // MARK: - Summary table

    private static func printSummaryTable(results: [Result]) {
        var lookup: [Int: [Mode: Result]] = [:]
        for r in results { lookup[r.limit, default: [:]][r.mode] = r }

        let tw = 9   // time column width
        let rw = 8   // result-count column width
        let qw = 15  // query column width
        let modes = Mode.allCases

        // Each limit group: 4 time columns + 1 result column + separating spaces
        let groupW = tw * modes.count + rw + modes.count
        let totalW = qw + limits.count * (groupW + 3)

        // Header row 1: query | limit=-1 ... | limit=100 ...
        var h1 = rpad("query", qw)
        for limit in limits {
            h1 += " | " + rpad("limit=\(limit)", groupW)
        }
        print(h1)

        // Header row 2: mode short labels + "results" per group
        var h2 = rpad("", qw)
        for _ in limits {
            let cols = modes.map { lpad($0.shortLabel, tw) } + [lpad("results", rw)]
            h2 += " | " + cols.joined(separator: " ")
        }
        print(h2)

        print(String(repeating: "-", count: totalW))

        // Data rows
        for (qi, q) in queries.enumerated() {
            var row = rpad(q, qw)
            for limit in limits {
                let dict = lookup[limit] ?? [:]
                let cells = modes.map { mode -> String in
                    guard let r = dict[mode] else { return lpad("-", tw) }
                    return lpad(String(format: "%.1f", Double(r.perQueryNs[qi]) / 1_000_000), tw)
                }
                let count = dict[.both]?.perQueryResults[qi].description ?? "-"
                row += " | " + (cells + [lpad(count, rw)]).joined(separator: " ")
            }
            print(row)
        }
    }

    // MARK: - Helpers

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func fmt(_ ns: UInt64) -> String {
        String(format: "%.3f", Double(ns) / 1_000_000)
    }

    private static func measure<T>(_ body: () -> T) -> (T, UInt64) {
        let t0 = now(); let v = body(); return (v, now() - t0)
    }

    private static func rpad(_ s: String, _ w: Int) -> String {
        let n = displayWidth(s)
        return n >= w ? s : s + String(repeating: " ", count: w - n)
    }

    private static func lpad(_ s: String, _ w: Int) -> String {
        let n = displayWidth(s)
        return n >= w ? s : String(repeating: " ", count: w - n) + s
    }

    private static func pad(_ s: String, _ w: Int) -> String { rpad(s, w) }

    private static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { sum, s in
            let v = s.value
            if (0x0300...0x036F).contains(v) || (0xFE00...0xFE0F).contains(v) ||
               (0x20D0...0x20FF).contains(v) || (0xFE20...0xFE2F).contains(v) { return sum }
            if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) ||
               (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) ||
               (0xFF00...0xFF60).contains(v) || (0x1F300...0x1F9FF).contains(v) ||
               (0x20000...0x3FFFD).contains(v) { return sum + 2 }
            return sum + 1
        }
    }

    private static func loadDatabase() throws -> WorldCitiesDB<City> {
        let cityURL = URL(fileURLWithPath: "Sources/WorldCitiesDB/Resources/cities.wcdb")
        return try WorldCitiesDB<City>(data: Data(contentsOf: cityURL))
    }
}
