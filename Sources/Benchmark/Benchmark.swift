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
        let args = Array(CommandLine.arguments.dropFirst())

        if args == ["--fold-lookup"] {
            FoldLookupBench.run()
            return
        }

        let markdownOutputPath: String?
        if args.isEmpty {
            markdownOutputPath = nil
        } else if args.count == 2, args[0] == "--markdown" {
            markdownOutputPath = args[1]
        } else {
            fputs("Usage: Benchmark [--fold-lookup] [--markdown <path>]\n", stderr)
            Darwin.exit(1)
        }

        print("WorldCitiesDB Search Benchmark")
        let environment = benchmarkEnvironmentLine()
        print("environment: \(environment)")
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

        if let markdownOutputPath {
            try writeMarkdownReport(
                to: markdownOutputPath,
                db: db,
                dbLoadNs: dbMs,
                environment: environment,
                results: results
            )
            print("\nwrote benchmark report to \(markdownOutputPath)")
        }

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

    private static func writeMarkdownReport(
        to path: String,
        db: WorldCitiesDB<City>,
        dbLoadNs: UInt64,
        environment: String,
        results: [Result]
    ) throws {
        let report = markdownReport(
            db: db,
            dbLoadNs: dbLoadNs,
            environment: environment,
            results: results
        )
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try report.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func markdownReport(
        db: WorldCitiesDB<City>,
        dbLoadNs: UInt64,
        environment: String,
        results: [Result]
    ) -> String {
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let casefoldingCache = db.casefoldingCache

        var lines: [String] = []
        lines.append("# WorldCitiesDB Benchmark Results")
        lines.append("")
        lines.append("Generated by `swift run -c release Benchmark --markdown BENCHMARK.md`.")
        lines.append("")
        lines.append("- Environment: `\(markdownCell(environment))`")
        lines.append("- Generated at: `\(generatedAt)`")
        lines.append("- Source database generated at: `\(db.metadata.generatedAt)`")
        lines.append("- City count: `\(db.count)`")
        lines.append("- Database load time: `\(fmt(dbLoadNs)) ms`")
        lines.append("- Casefold cache: `\(casefoldingCache.entryCount)` entries, `\(casefoldingCache.totalBytes / 1024) KB` total")
        lines.append("- Limits: `\(limits)`")
        lines.append("- Queries: `\(queries.count)`")
        lines.append("")
        lines.append("Times are milliseconds from a release build on the GitHub Actions `macos-latest` runner unless generated locally.")
        lines.append("The `results` column is the match count from the `Casefold + Search` mode.")
        lines.append("")
        lines.append("## Average/Min/Max Time Per Query")
        lines.append("")
        lines.append("| Limit | Mode | Average | Min | Max |")
        lines.append("| --- | --- | ---: | ---: | ---: |")

        let lookup = resultLookup(results)
        for limit in limits {
            let dict = lookup[limit] ?? [:]
            for mode in Mode.allCases {
                let stats = dict[mode].map(queryTimingStats)
                lines.append(
                    "| `\(limit)` | \(mode.label) | \(markdownMs(stats?.averageNs)) | \(markdownMs(stats?.minNs)) | \(markdownMs(stats?.maxNs)) |"
                )
            }
        }

        lines.append("")
        lines.append("## Detailed Per Query Timing")
        lines.append("")
        lines.append("| Query | Limit | No indexes | Casefold only | Search index only | Casefold + Search | Results |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")

        for (queryIndex, query) in queries.enumerated() {
            for limit in limits {
                let dict = lookup[limit] ?? [:]
                let resultCount = dict[.both]?.perQueryResults[queryIndex].description ?? "-"
                lines.append(
                    "| `\(markdownCell(query))` | `\(limit)` | \(markdownMs(dict[.none]?.perQueryNs[queryIndex], decimals: 1)) | \(markdownMs(dict[.casefold]?.perQueryNs[queryIndex], decimals: 1)) | \(markdownMs(dict[.searchIndex]?.perQueryNs[queryIndex], decimals: 1)) | \(markdownMs(dict[.both]?.perQueryNs[queryIndex], decimals: 1)) | \(resultCount) |"
                )
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func resultLookup(_ results: [Result]) -> [Int: [Mode: Result]] {
        var lookup: [Int: [Mode: Result]] = [:]
        for result in results {
            lookup[result.limit, default: [:]][result.mode] = result
        }
        return lookup
    }

    private static func queryTimingStats(_ result: Result) -> (averageNs: UInt64, minNs: UInt64, maxNs: UInt64) {
        guard let minNs = result.perQueryNs.min(),
              let maxNs = result.perQueryNs.max(),
              !result.perQueryNs.isEmpty else {
            return (0, 0, 0)
        }
        let total = result.perQueryNs.reduce(UInt64(0), &+)
        return (total / UInt64(result.perQueryNs.count), minNs, maxNs)
    }

    private static func markdownMs(_ ns: UInt64?, decimals: Int = 3) -> String {
        guard let ns else { return "-" }
        return String(format: "%.\(decimals)f", Double(ns) / 1_000_000)
    }

    private static func markdownCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func benchmarkEnvironmentLine() -> String {
        let hardwareModel = sysctlString("hw.model") ?? "unknown"
        let machine = sysctlString("hw.machine") ?? "unknown"
        let physicalCPU = sysctlInt("hw.physicalcpu").map(String.init) ?? "unknown"
        let logicalCPU = sysctlInt("hw.logicalcpu").map(String.init) ?? "unknown"
        let memory = sysctlUInt64("hw.memsize").map { "\(max(1, $0 / 1024 / 1024 / 1024)) GB RAM" } ?? "unknown RAM"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let compiler = commandFirstLine("/usr/bin/env", arguments: ["swiftc", "--version"])
            ?? commandFirstLine("/usr/bin/env", arguments: ["swift", "--version"])
            ?? "unknown Swift compiler"

        return "hardware=\(hardwareModel) (\(machine), \(physicalCPU) physical/\(logicalCPU) logical CPUs, \(memory)); os=\(os); compiler=\(compiler)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }

        let byteCount = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<byteCount].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func commandFirstLine(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
