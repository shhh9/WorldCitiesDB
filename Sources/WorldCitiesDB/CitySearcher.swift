import Foundation

/// Protocol for city types that support search. Implement to define which fields are searchable.
public protocol SearchableCity: Sendable {
    /// Return true if any ASCII field matches using the provided test closure (case-insensitive).
    func matchesASCII(_ test: (_ field: String) -> Bool) -> Bool
    /// Return true if any UTF-8 field matches using the provided test closure (exact match).
    func matchesUTF8(_ test: (_ field: String) -> Bool) -> Bool
}

/// Searches an array of cities using full scan. Cities must be pre-sorted by population (desc).
public final class CitySearcher<C: SearchableCity>: Sendable {
    private let cities: [C]

    public init(cities: [C]) {
        self.cities = cities
    }

    /// One-shot search. Returns up to `limit` results sorted by population (array order).
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
    /// Indices into `cities` of verified matches for lastQuery, in population order.
    private var lastMatches: [Int32] = []

    /// Whether the last query is a deferred 1-char query (no scan performed yet).
    private var isPendingScan: Bool {
        guard let q = lastQuery else { return false }
        return q.value.unicodeScalars.count == 1 && lastMatches.isEmpty
    }

    init(cities: [C]) {
        self.cities = cities
    }

    /// Updates the search with a new query string.
    public func update(query rawQuery: String) {
        let query = Query(rawQuery)
        defer { lastQuery = query }

        // Empty or 1-char query: defer scan to results()
        if query.value.unicodeScalars.count <= 1 {
            lastMatches = []
            return
        }

        // Incremental: new query extends previous
        if let lastQuery, !lastQuery.value.isEmpty,
           query.value.hasPrefix(lastQuery.value), query.value != lastQuery.value {
            if isPendingScan {
                // Previous was deferred 1-char — do full scan
                fullScan(query)
                return
            }
            // Filter cached matches
            lastMatches = lastMatches.filter {
                Self.matchesCity(cities[Int($0)], query: query)
            }
            return
        }

        // Full recompute
        fullScan(query)
    }

    /// Returns up to `limit` results. Use `-1` for all results.
    public func results(limit: Int = 20) -> [C] {
        guard let query = lastQuery, !query.value.isEmpty else {
            let effectiveLimit = limit < 0 ? cities.count : limit
            return Array(cities.prefix(effectiveLimit))
        }

        let effectiveLimit = limit < 0 ? Int.max : limit

        // Handle deferred 1-char scan
        if isPendingScan {
            var results: [C] = []
            var indices: [Int32] = []
            for i in 0..<cities.count {
                if Self.matchesCity(cities[i], query: query) {
                    indices.append(Int32(i))
                    results.append(cities[i])
                    if results.count >= effectiveLimit { break }
                }
            }
            lastMatches = indices
            return results
        }

        return Array(lastMatches.prefix(effectiveLimit).map { cities[Int($0)] })
    }

    // MARK: - Private

    private func fullScan(_ query: Query) {
        var matches: [Int32] = []
        for i in 0..<cities.count {
            if Self.matchesCity(cities[i], query: query) {
                matches.append(Int32(i))
            }
        }
        // cities already sorted by population, so matches preserve order
        lastMatches = matches
    }

    /// Checks whether a city matches the query.
    private static func matchesCity(_ city: C, query: Query) -> Bool {
        if query.isASCII {
            // ASCII query: check ASCII fields first (case-insensitive),
            // then UTF-8 fields (which may contain ASCII substrings)
            return city.matchesASCII { field in
                containsASCII(field, query)
            } || city.matchesUTF8 { field in
                containsASCII(field, query)
            }
        }

        // Non-ASCII query: only check UTF-8 fields.
        // ASCII fields can never contain non-ASCII bytes, so skip them.
        return city.matchesUTF8 { field in
            containsUTF8(field, query)
        }
    }

    /// Case-insensitive ASCII substring search via inline byte folding.
    private static func containsASCII(_ haystack: String, _ query: Query) -> Bool {
        var h = haystack
        var q = query.value
        return h.withUTF8 { hBuf in
            q.withUTF8 { qBuf in
                let hLen = hBuf.count
                let qLen = qBuf.count
                guard qLen > 0, qLen <= hLen else { return qLen == 0 }

                let limit = hLen - qLen
                for i in 0...limit {
                    let hByte = hBuf[i]
                    if hByte >= 0x80 { continue }
                    let hLower = (hByte >= 0x41 && hByte <= 0x5A) ? hByte &+ 0x20 : hByte
                    if hLower == qBuf[0] {
                        var matched = true
                        for j in 1..<qLen {
                            let hb = hBuf[i + j]
                            if hb >= 0x80 { matched = false; break }
                            let hl = (hb >= 0x41 && hb <= 0x5A) ? hb &+ 0x20 : hb
                            if hl != qBuf[j] {
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
    }

    /// Case-insensitive UTF-8 substring search.
    /// Three pointers (haystack, lower query, upper query) each at the start of
    /// the current character. From the leading byte we know each char's byte length.
    /// We compare the haystack char bytes against lower — if match, advance all three.
    /// Otherwise compare against upper — if match, advance all three.
    /// Otherwise no match at this starting position.
    private static func containsUTF8(_ haystack: String, _ query: Query) -> Bool {
        var h = haystack
        let lo = query.lowerBytes
        let up = query.upperBytes
        let loLen = lo.count
        let upLen = up.count
        return h.withUTF8 { hBuf in
            let hLen = hBuf.count
            guard loLen > 0 else { return true }
            guard min(loLen, upLen) <= hLen else { return false }

            for i in 0..<hLen {
                var hPtr = i, lPtr = 0, uPtr = 0

                while lPtr < loLen && uPtr < upLen {
                    let hb = hBuf[hPtr]
                    let hCharLen = utf8CharLen(hb)
                    let lCharLen = utf8CharLen(lo[lPtr])
                    let uCharLen = utf8CharLen(up[uPtr])

                    if hCharLen == lCharLen && charsEqual(hBuf, hPtr, lo, lPtr, hCharLen) {
                        hPtr += hCharLen; lPtr += lCharLen; uPtr += uCharLen; continue
                    }
                    if hCharLen == uCharLen && charsEqual(hBuf, hPtr, up, uPtr, hCharLen) {
                        hPtr += hCharLen; lPtr += lCharLen; uPtr += uCharLen; continue
                    }
                    break
                }
                if lPtr == loLen { return true }

                // No point trying starting positions beyond where the query can't fit
                if hLen - i < min(loLen, upLen) { break }
            }
            return false
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
    let lowerBytes: [UInt8]
    let upperBytes: [UInt8]

    init(_ rawQuery: String) {
        let lowered = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        self.value = lowered
        var ascii = true
        for byte in lowered.utf8 {
            if byte >= 0x80 { ascii = false; break }
        }
        self.isASCII = ascii
        let uppered = lowered.uppercased()
        self.isCaseInvariant = !ascii && uppered == lowered
        self.lowerBytes = Array(lowered.utf8)
        self.upperBytes = Array(uppered.utf8)
    }
}

/// Returns the byte length of a UTF-8 character from its leading byte.
@inline(__always)
func utf8CharLen(_ b: UInt8) -> Int {
    if b < 0x80 { return 1 }
    if b < 0xE0 { return 2 }
    if b < 0xF0 { return 3 }
    return 4
}

/// Compares a UTF-8 character's bytes between two buffers. Length is 1–4.
@inline(__always)
func charsEqual(
    _ a: UnsafeBufferPointer<UInt8>, _ ai: Int,
    _ b: [UInt8], _ bi: Int,
    _ len: Int
) -> Bool {
    switch len {
    case 1: return a[ai] == b[bi]
    case 2: return a[ai] == b[bi] && a[ai+1] == b[bi+1]
    case 3: return a[ai] == b[bi] && a[ai+1] == b[bi+1] && a[ai+2] == b[bi+2]
    default: return a[ai] == b[bi] && a[ai+1] == b[bi+1] && a[ai+2] == b[bi+2] && a[ai+3] == b[bi+3]
    }
}
