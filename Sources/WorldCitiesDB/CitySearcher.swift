import Foundation

/// Protocol for city types that support search. Implement to define which fields are searchable.
public protocol SearchableCity: Sendable {
    /// Return true if any ASCII field matches using the provided test closure (case-insensitive).
    func matchesASCII(_ test: (_ field: String) -> Bool) -> Bool
    /// Return true if any UTF-8 field matches using the provided test closure.
    func matchesUTF8(_ test: (_ field: String) -> Bool) -> Bool
    /// Return true if a primary ASCII field (typically `asciiName`) matches.
    func matchesPrimaryASCII(_ test: (_ field: String) -> Bool) -> Bool
    /// Return true if a secondary/alternate ASCII field matches.
    func matchesAlternateASCII(_ test: (_ field: String) -> Bool) -> Bool
    /// Return true if a primary UTF-8 field (typically `name`) matches.
    func matchesPrimaryUTF8(_ test: (_ field: String) -> Bool) -> Bool
    /// Return true if a secondary/alternate UTF-8 field matches.
    func matchesAlternateUTF8(_ test: (_ field: String) -> Bool) -> Bool
}

public extension SearchableCity {
    // Backward-compatible defaults: existing conformers keep the old behavior.
    func matchesPrimaryASCII(_ test: (_ field: String) -> Bool) -> Bool { matchesASCII(test) }
    func matchesAlternateASCII(_ test: (_ field: String) -> Bool) -> Bool { false }
    func matchesPrimaryUTF8(_ test: (_ field: String) -> Bool) -> Bool { matchesUTF8(test) }
    func matchesAlternateUTF8(_ test: (_ field: String) -> Bool) -> Bool { false }
}

/// Searches an array of cities using full scan. Cities must be pre-sorted by population (desc).
public final class CitySearcher<C: SearchableCity>: Sendable {
    private let cities: [C]

    public init(cities: [C]) {
        self.cities = cities
    }

    /// One-shot search.
    ///
    /// Results are ordered by:
    /// 1) primary name field matches (e.g. `name`, `asciiName`) by population,
    /// 2) alternate name field matches by population.
    public func search(query: String, limit: Int = 20) -> [C] {
        let ctx = newSearch()
        ctx.update(query: query)
        return ctx.results(limit: limit)
    }

    /// Creates a new progressive search context.
    public func newSearch() -> SearchContext<C> {
        SearchContext(cities: cities)
    }
}

/// Stateful search context for progressive query refinement.
///
/// Caches matched city indices so that extending a query (prefix match) narrows
/// the cached set instead of rescanning from scratch.
///
/// ```swift
/// let ctx = searcher.newSearch()
/// ctx.update(query: "new")
/// ctx.update(query: "new yo")       // filters cached matches
/// ctx.update(query: "new york")     // filters further
/// ctx.update(query: "paris")        // not a prefix → full recompute
/// let results = ctx.results(limit: 20)
/// ```
public final class SearchContext<C: SearchableCity> {
    private let cities: [C]

    private var lastQuery: Query?
    /// Matches in primary name fields, in population order.
    private var lastPrimaryMatches: [Int32] = []
    /// Matches in alternate name fields, in population order.
    private var lastAlternateMatches: [Int32] = []

    init(cities: [C]) {
        self.cities = cities
    }

    /// Updates the search with a new query string.
    public func update(query rawQuery: String) {
        let query = Query(rawQuery)
        if query.value.isEmpty {
            lastPrimaryMatches.removeAll(keepingCapacity: true)
            lastAlternateMatches.removeAll(keepingCapacity: true)
            lastQuery = query
            return
        }

        if let previousQuery = lastQuery, query.value == previousQuery.value {
            return
        }

        // Incremental: new query extends previous
        if let previousQuery = lastQuery, !previousQuery.value.isEmpty,
           query.value.hasPrefix(previousQuery.value), query.value != previousQuery.value {
            // Filter cached matches
            filterCachedMatches(query)
        } else {
            // Full recompute
            fullScan(query)
        }
        lastQuery = query
    }

    /// Returns up to `limit` results. Use `-1` for all results.
    public func results(limit: Int = 20) -> [C] {
        guard let lastQuery, !lastQuery.value.isEmpty else {
            let effectiveLimit = Self.normalizedLimit(limit, total: cities.count)
            return Array(cities.prefix(effectiveLimit))
        }

        return materializeResults(limit: limit)
    }

    // MARK: - Private

    private func fullScan(_ query: Query) {
        var primary: [Int32] = []
        var alternate: [Int32] = []
        for i in 0..<cities.count {
            let idx = Int32(i)
            switch Self.matchKind(cities[i], query: query) {
            case .primary:
                primary.append(idx)
            case .alternate:
                alternate.append(idx)
            case .none:
                continue
            }
        }
        lastPrimaryMatches = primary
        lastAlternateMatches = alternate
    }

    /// Filters cached candidates when the query is extended.
    /// Candidates are merged by index to keep population order stable.
    private func filterCachedMatches(_ query: Query) {
        var nextPrimary: [Int32] = []
        var nextAlternate: [Int32] = []
        nextPrimary.reserveCapacity(lastPrimaryMatches.count)
        nextAlternate.reserveCapacity(lastAlternateMatches.count)

        var i = 0
        var j = 0
        while i < lastPrimaryMatches.count || j < lastAlternateMatches.count {
            let idx: Int32
            if j >= lastAlternateMatches.count ||
                (i < lastPrimaryMatches.count && lastPrimaryMatches[i] < lastAlternateMatches[j]) {
                idx = lastPrimaryMatches[i]
                i += 1
            } else {
                idx = lastAlternateMatches[j]
                j += 1
            }

            switch Self.matchKind(cities[Int(idx)], query: query) {
            case .primary:
                nextPrimary.append(idx)
            case .alternate:
                nextAlternate.append(idx)
            case .none:
                continue
            }
        }

        lastPrimaryMatches = nextPrimary
        lastAlternateMatches = nextAlternate
    }

    private func materializeResults(limit: Int) -> [C] {
        let total = lastPrimaryMatches.count + lastAlternateMatches.count
        let effectiveLimit = Self.normalizedLimit(limit, total: total)
        guard effectiveLimit > 0 else { return [] }

        var results: [C] = []
        results.reserveCapacity(effectiveLimit)

        let primaryCount = min(effectiveLimit, lastPrimaryMatches.count)
        for idx in lastPrimaryMatches.prefix(primaryCount) {
            results.append(cities[Int(idx)])
        }
        if results.count == effectiveLimit {
            return results
        }

        let remaining = effectiveLimit - results.count
        for idx in lastAlternateMatches.prefix(remaining) {
            results.append(cities[Int(idx)])
        }
        return results
    }

    private static func normalizedLimit(_ limit: Int, total: Int) -> Int {
        if limit < 0 { return total }
        if limit == 0 { return 0 }
        return min(limit, total)
    }

    /// Checks whether a city matches the query and in which tier.
    private static func matchKind(_ city: C, query: Query) -> MatchKind {
        if query.isASCII {
            let test: (String) -> Bool = { field in
                containsASCII(field, query)
            }

            if city.matchesPrimaryASCII(test) || city.matchesPrimaryUTF8(test) {
                return .primary
            }
            if city.matchesAlternateASCII(test) || city.matchesAlternateUTF8(test) {
                return .alternate
            }
            return .none
        }

        let test: (String) -> Bool = { field in
            containsUTF8(field, query)
        }
        if city.matchesPrimaryUTF8(test) {
            return .primary
        }
        if city.matchesAlternateUTF8(test) {
            return .alternate
        }
        return .none
    }

    private enum MatchKind {
        case none
        case primary
        case alternate
    }

    /// Case-insensitive ASCII substring search via inline byte folding.
    private static func containsASCII(_ haystack: String, _ query: Query) -> Bool {
        var h = haystack
        let qBytes = query.lowerBytes
        return h.withUTF8 { hBuf in
            let hLen = hBuf.count
            let qLen = qBytes.count
            guard qLen > 0, qLen <= hLen else { return qLen == 0 }

            let first = qBytes[0]
            let limit = hLen - qLen
            for i in 0...limit {
                let hByte = hBuf[i]
                if hByte >= 0x80 { continue }
                let hLower = (hByte >= 0x41 && hByte <= 0x5A) ? hByte &+ 0x20 : hByte
                if hLower == first {
                    var matched = true
                    for j in 1..<qLen {
                        let hb = hBuf[i + j]
                        if hb >= 0x80 { matched = false; break }
                        let hl = (hb >= 0x41 && hb <= 0x5A) ? hb &+ 0x20 : hb
                        if hl != qBytes[j] {
                            matched = false
                            break
                        }
                    }
                    if matched { return true }
                }
            }
            return false
        }
    }

    /// Case-insensitive UTF-8 substring search.
    ///
    /// For scripts with no case, this is a raw byte substring scan.
    /// For case-varying scripts, use a 3-pointer scan against lower/upper query bytes.
    /// For rare complex case mappings (scalar-count changes), fallback to Foundation.
    private static func containsUTF8(_ haystack: String, _ query: Query) -> Bool {
        if query.isCaseInvariant {
            return containsBytes(haystack, needle: query.lowerBytes)
        }
        if query.hasComplexCaseMapping {
            return haystack.range(of: query.value, options: [.caseInsensitive, .literal]) != nil
        }

        var h = haystack
        let lo = query.lowerBytes
        let up = query.upperBytes
        let loLen = lo.count
        let upLen = up.count

        return h.withUTF8 { hBuf in
            let hLen = hBuf.count
            guard loLen > 0 else { return true }
            guard loLen <= hLen else { return false }
            guard upLen > 0 else { return false }

            var start = 0
            while start < hLen {
                let startCharLen = utf8LeadingCharLen(hBuf[start])
                if startCharLen == 0 || start + startCharLen > hLen {
                    start += 1
                    continue
                }

                var hPtr = start
                var lPtr = 0
                var uPtr = 0
                var matched = true

                while lPtr < loLen {
                    guard hPtr < hLen, uPtr < upLen else {
                        matched = false
                        break
                    }

                    let hCharLen = utf8LeadingCharLen(hBuf[hPtr])
                    let lCharLen = utf8LeadingCharLen(lo[lPtr])
                    let uCharLen = utf8LeadingCharLen(up[uPtr])

                    guard hCharLen > 0, lCharLen > 0, uCharLen > 0,
                          hPtr + hCharLen <= hLen,
                          lPtr + lCharLen <= loLen,
                          uPtr + uCharLen <= upLen else {
                        matched = false
                        break
                    }

                    if hCharLen == lCharLen && bytesEqual(hBuf, hPtr, lo, lPtr, hCharLen) {
                        hPtr += hCharLen
                        lPtr += lCharLen
                        uPtr += uCharLen
                        continue
                    }
                    if hCharLen == uCharLen && bytesEqual(hBuf, hPtr, up, uPtr, hCharLen) {
                        hPtr += hCharLen
                        lPtr += lCharLen
                        uPtr += uCharLen
                        continue
                    }

                    matched = false
                    break
                }

                if matched, lPtr == loLen, uPtr == upLen {
                    return true
                }

                // Try next valid UTF-8 character boundary as the start.
                start += startCharLen
            }
            return false
        }
    }

    @inline(__always)
    private static func containsBytes(_ haystack: String, needle: [UInt8]) -> Bool {
        var h = haystack
        return h.withUTF8 { hBuf in
            let hLen = hBuf.count
            let qLen = needle.count
            guard qLen > 0, qLen <= hLen else { return qLen == 0 }

            let first = needle[0]
            let limit = hLen - qLen
            for i in 0...limit {
                if hBuf[i] != first { continue }

                var matched = true
                for j in 1..<qLen {
                    if hBuf[i + j] != needle[j] {
                        matched = false
                        break
                    }
                }
                if matched { return true }
            }
            return false
        }
    }

    /// Returns UTF-8 character length for a leading byte, or 0 for continuation/invalid.
    @inline(__always)
    private static func utf8LeadingCharLen(_ b: UInt8) -> Int {
        if b < 0x80 { return 1 }
        if b < 0xC0 { return 0 } // continuation byte
        if b < 0xE0 { return 2 }
        if b < 0xF0 { return 3 }
        if b < 0xF8 { return 4 }
        return 0
    }

    /// Compares `len` bytes between haystack buffer and query byte array.
    @inline(__always)
    private static func bytesEqual(
        _ a: UnsafeBufferPointer<UInt8>, _ ai: Int,
        _ b: [UInt8], _ bi: Int,
        _ len: Int
    ) -> Bool {
        switch len {
        case 1:
            return a[ai] == b[bi]
        case 2:
            return a[ai] == b[bi] && a[ai + 1] == b[bi + 1]
        case 3:
            return a[ai] == b[bi] && a[ai + 1] == b[bi + 1] && a[ai + 2] == b[bi + 2]
        default:
            return a[ai] == b[bi] && a[ai + 1] == b[bi + 1] && a[ai + 2] == b[bi + 2] && a[ai + 3] == b[bi + 3]
        }
    }
}

// MARK: - Query

/// Lowercased query string with pre-computed properties for fast substring matching.
struct Query {
    let value: String
    let isASCII: Bool
    /// Whether the query is case-invariant (e.g. CJK, Arabic) — lowercased == uppercased.
    let isCaseInvariant: Bool
    /// Rare case where lowercase/uppercase changed scalar count (e.g. ß -> SS).
    let hasComplexCaseMapping: Bool
    let lowerBytes: [UInt8]
    let upperBytes: [UInt8]

    init(_ rawQuery: String) {
        let lowered = rawQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = lowered
        var ascii = true
        for byte in lowered.utf8 {
            if byte >= 0x80 { ascii = false; break }
        }
        self.isASCII = ascii
        let uppered = lowered.uppercased()
        self.isCaseInvariant = !ascii && uppered == lowered
        self.hasComplexCaseMapping = !ascii && lowered.unicodeScalars.count != uppered.unicodeScalars.count
        self.lowerBytes = Array(lowered.utf8)
        self.upperBytes = Array(uppered.utf8)
    }
}
