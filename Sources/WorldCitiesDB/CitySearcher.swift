import Foundation

/// Protocol for city types that support search. Implement to define which fields are searchable.
public protocol SearchableCity: Sendable {
    /// Call test on each primary field (e.g. name, asciiName). Return true on first match.
    func matchesPrimaryField(_ test: (String) -> Bool) -> Bool
    /// Call test on each alternate field. Return true on first match.
    func matchesAlternateField(_ test: (String) -> Bool) -> Bool
}

/// Searches an array of cities using a bitmap index. Cities must be pre-sorted by population (desc).
public final class CitySearcher<C: SearchableCity>: Sendable {
    let cities: [C]

    // Bitmap index: 36 chars (a-z=0-25, 0-9=26-35), each with wordCount UInt64s
    let bitmaps: [UInt64]
    let wordCount: Int

    public init(cities: [C]) {
        self.cities = cities
        let count = cities.count
        let wc = (count + 63) / 64
        self.wordCount = wc

        // Build bitmap index
        var bm = [UInt64](repeating: 0, count: 36 * wc)
        for i in 0..<count {
            let wordIdx = i / 64
            let bitMask: UInt64 = 1 << (i % 64)

            // Closure that records ASCII chars from a field
            let record: (String) -> Bool = { field in
                var f = field
                f.withUTF8 { buf in
                    for k in 0..<buf.count {
                        let b = buf[k]
                        let slot: Int
                        if b >= 0x61 && b <= 0x7A {       // a-z
                            slot = Int(b - 0x61)
                        } else if b >= 0x41 && b <= 0x5A { // A-Z → lowercase
                            slot = Int(b - 0x41)
                        } else if b >= 0x30 && b <= 0x39 { // 0-9
                            slot = Int(b - 0x30) + 26
                        } else {
                            continue
                        }
                        bm[slot * wc + wordIdx] |= bitMask
                    }
                }
                return false // return false to iterate all fields
            }

            _ = cities[i].matchesPrimaryField(record)
            _ = cities[i].matchesAlternateField(record)
        }
        self.bitmaps = bm
    }

    /// One-shot search with bitmap filtering and early-exit.
    ///
    /// Results are ordered by:
    /// 1) primary name field matches by population,
    /// 2) alternate name field matches by population.
    public func search(query: String, limit: Int = 20) -> [C] {
        let q = Query(query)
        if q.value.isEmpty {
            let effectiveLimit = limit < 0 ? cities.count : min(limit, cities.count)
            return Array(cities.prefix(effectiveLimit))
        }

        let effectiveLimit = limit < 0 ? cities.count : limit
        let asciiChars = q.asciiChars

        if !asciiChars.isEmpty {
            // Build candidate bitmap by ANDing character bitmaps
            var candidateBitmap = [UInt64](repeating: UInt64.max, count: wordCount)
            for charSlot in asciiChars {
                let offset = charSlot * wordCount
                for w in 0..<wordCount {
                    candidateBitmap[w] &= bitmaps[offset + w]
                }
            }

            var primary: [C] = []
            var alternate: [C] = []

            for w in 0..<wordCount {
                var bits = candidateBitmap[w]
                while bits != 0 {
                    let bit = bits.trailingZeroBitCount
                    bits &= bits &- 1
                    let idx = w * 64 + bit
                    if idx >= cities.count { break }

                    let city = cities[idx]
                    switch matchKind(city, query: q) {
                    case .primary:
                        primary.append(city)
                        if primary.count >= effectiveLimit {
                            let remaining = effectiveLimit - primary.count
                            if remaining > 0 {
                                return Array(primary.prefix(effectiveLimit)) + Array(alternate.prefix(remaining))
                            }
                            return Array(primary.prefix(effectiveLimit))
                        }
                    case .alternate:
                        if alternate.count < effectiveLimit {
                            alternate.append(city)
                        }
                    case .none:
                        break
                    }
                }
            }

            let remaining = effectiveLimit - primary.count
            if remaining > 0 {
                return primary + Array(alternate.prefix(remaining))
            }
            return primary
        } else {
            // Pure non-ASCII (e.g. CJK) — linear scan
            var primary: [C] = []
            var alternate: [C] = []

            for i in 0..<cities.count {
                let city = cities[i]
                switch matchKind(city, query: q) {
                case .primary:
                    primary.append(city)
                    if primary.count >= effectiveLimit {
                        let remaining = effectiveLimit - primary.count
                        if remaining > 0 {
                            return Array(primary.prefix(effectiveLimit)) + Array(alternate.prefix(remaining))
                        }
                        return Array(primary.prefix(effectiveLimit))
                    }
                case .alternate:
                    if alternate.count < effectiveLimit {
                        alternate.append(city)
                    }
                case .none:
                    break
                }
            }

            let remaining = effectiveLimit - primary.count
            if remaining > 0 {
                return primary + Array(alternate.prefix(remaining))
            }
            return primary
        }
    }

    /// Creates a new progressive search context.
    public func newSearch() -> SearchContext<C> {
        SearchContext(searcher: self)
    }

    // MARK: - Match Classification

    private enum MatchKind {
        case none
        case primary
        case alternate
    }

    /// Checks whether a city matches the query and in which tier.
    private func matchKind(_ city: C, query: Query) -> MatchKind {
        if query.isASCII {
            let test: (String) -> Bool = { field in
                Self.containsASCII(field, query)
            }
            if city.matchesPrimaryField(test) { return .primary }
            if city.matchesAlternateField(test) { return .alternate }
            return .none
        }

        if query.isCaseInvariant {
            let test: (String) -> Bool = { field in
                Self.containsBytes(field, needle: query.lowerBytes)
            }
            if city.matchesPrimaryField(test) { return .primary }
            if city.matchesAlternateField(test) { return .alternate }
            return .none
        }

        if query.hasComplexCaseMapping {
            let test: (String) -> Bool = { field in
                field.range(of: query.value, options: [.caseInsensitive, .literal]) != nil
            }
            if city.matchesPrimaryField(test) { return .primary }
            if city.matchesAlternateField(test) { return .alternate }
            return .none
        }

        let test: (String) -> Bool = { field in
            Self.containsUTF8(field, query)
        }
        if city.matchesPrimaryField(test) { return .primary }
        if city.matchesAlternateField(test) { return .alternate }
        return .none
    }

    // MARK: - Substring Matching

    /// Case-insensitive ASCII substring search via inline byte folding.
    static func containsASCII(_ haystack: String, _ query: Query) -> Bool {
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

    /// Case-insensitive UTF-8 substring search with early-exit optimization.
    ///
    /// For case-varying scripts, uses a 3-pointer scan against lower/upper query bytes.
    static func containsUTF8(_ haystack: String, _ query: Query) -> Bool {
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
                // Early exit: not enough bytes remaining
                if hLen - start < loLen { return false }

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

                start += startCharLen
            }
            return false
        }
    }

    @inline(__always)
    static func containsBytes(_ haystack: String, needle: [UInt8]) -> Bool {
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
    static func utf8LeadingCharLen(_ b: UInt8) -> Int {
        if b < 0x80 { return 1 }
        if b < 0xC0 { return 0 } // continuation byte
        if b < 0xE0 { return 2 }
        if b < 0xF0 { return 3 }
        if b < 0xF8 { return 4 }
        return 0
    }

    /// Compares `len` bytes between haystack buffer and query byte array.
    @inline(__always)
    static func bytesEqual(
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

// MARK: - SearchContext

/// Stateful search context for progressive query refinement.
///
/// Caches matched city indices and candidate bitmaps so that extending a query
/// (prefix match) narrows the cached set instead of rescanning from scratch.
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
    private let searcher: CitySearcher<C>
    private var cities: [C] { searcher.cities }

    private var lastQuery: Query?
    private var candidateBitmap: [UInt64]?
    /// Matches in primary name fields, in population order.
    private var lastPrimaryMatches: [Int32] = []
    /// Matches in alternate name fields, in population order.
    private var lastAlternateMatches: [Int32] = []

    init(searcher: CitySearcher<C>) {
        self.searcher = searcher
    }

    /// Updates the search with a new query string.
    public func update(query rawQuery: String) {
        let query = Query(rawQuery)
        if query.value.isEmpty {
            lastPrimaryMatches.removeAll(keepingCapacity: true)
            lastAlternateMatches.removeAll(keepingCapacity: true)
            candidateBitmap = nil
            lastQuery = query
            return
        }

        if let previousQuery = lastQuery, query.value == previousQuery.value {
            return
        }

        // Incremental: new query extends previous
        if let previousQuery = lastQuery, !previousQuery.value.isEmpty,
           query.value.hasPrefix(previousQuery.value), query.value != previousQuery.value {
            filterCachedMatches(query, previousQuery: previousQuery)
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
        let asciiChars = query.asciiChars

        // Build candidate bitmap
        candidateBitmap = computeCandidateBitmap(for: asciiChars)

        var primary: [Int32] = []
        var alternate: [Int32] = []

        if let bitmap = candidateBitmap {
            let wc = searcher.wordCount
            for w in 0..<wc {
                var bits = bitmap[w]
                while bits != 0 {
                    let bit = bits.trailingZeroBitCount
                    bits &= bits &- 1
                    let idx = w * 64 + bit
                    if idx >= cities.count { break }

                    switch matchKind(cities[idx], query: query) {
                    case .primary:
                        primary.append(Int32(idx))
                    case .alternate:
                        alternate.append(Int32(idx))
                    case .none:
                        break
                    }
                }
            }
        } else {
            // No ASCII chars — linear scan
            for i in 0..<cities.count {
                switch matchKind(cities[i], query: query) {
                case .primary:
                    primary.append(Int32(i))
                case .alternate:
                    alternate.append(Int32(i))
                case .none:
                    break
                }
            }
        }

        lastPrimaryMatches = primary
        lastAlternateMatches = alternate
    }

    /// Filters cached candidates when the query is extended.
    private func filterCachedMatches(_ query: Query, previousQuery: Query) {
        // Narrow the candidate bitmap with new ASCII chars
        let prevChars = Set(previousQuery.asciiChars)
        let newChars = query.asciiChars.filter { !prevChars.contains($0) }
        if !newChars.isEmpty, var bitmap = candidateBitmap {
            let wc = searcher.wordCount
            for charSlot in newChars {
                let offset = charSlot * wc
                for w in 0..<wc {
                    bitmap[w] &= searcher.bitmaps[offset + w]
                }
            }
            candidateBitmap = bitmap

            // Filter matches to only those still set in narrowed bitmap
            lastPrimaryMatches = lastPrimaryMatches.filter { idx in
                let w = Int(idx) / 64
                let bit: UInt64 = 1 << (Int(idx) % 64)
                return bitmap[w] & bit != 0
            }
            lastAlternateMatches = lastAlternateMatches.filter { idx in
                let w = Int(idx) / 64
                let bit: UInt64 = 1 << (Int(idx) % 64)
                return bitmap[w] & bit != 0
            }
        }

        // Re-verify survivors and reclassify
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

            switch matchKind(cities[Int(idx)], query: query) {
            case .primary:
                nextPrimary.append(idx)
            case .alternate:
                nextAlternate.append(idx)
            case .none:
                break
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

    // MARK: - Helpers

    /// Computes candidate bitmap by ANDing character bitmaps for given char slots.
    private func computeCandidateBitmap(for charSlots: [Int]) -> [UInt64]? {
        guard !charSlots.isEmpty else { return nil }
        let wc = searcher.wordCount
        var bitmap = [UInt64](repeating: UInt64.max, count: wc)
        for charSlot in charSlots {
            let offset = charSlot * wc
            for w in 0..<wc {
                bitmap[w] &= searcher.bitmaps[offset + w]
            }
        }
        return bitmap
    }

    private enum MatchKind {
        case none
        case primary
        case alternate
    }

    /// Checks whether a city matches the query and in which tier.
    private func matchKind(_ city: C, query: Query) -> MatchKind {
        if query.isASCII {
            let test: (String) -> Bool = { field in
                CitySearcher<C>.containsASCII(field, query)
            }
            if city.matchesPrimaryField(test) { return .primary }
            if city.matchesAlternateField(test) { return .alternate }
            return .none
        }

        if query.isCaseInvariant {
            let test: (String) -> Bool = { field in
                CitySearcher<C>.containsBytes(field, needle: query.lowerBytes)
            }
            if city.matchesPrimaryField(test) { return .primary }
            if city.matchesAlternateField(test) { return .alternate }
            return .none
        }

        if query.hasComplexCaseMapping {
            let test: (String) -> Bool = { field in
                field.range(of: query.value, options: [.caseInsensitive, .literal]) != nil
            }
            if city.matchesPrimaryField(test) { return .primary }
            if city.matchesAlternateField(test) { return .alternate }
            return .none
        }

        let test: (String) -> Bool = { field in
            CitySearcher<C>.containsUTF8(field, query)
        }
        if city.matchesPrimaryField(test) { return .primary }
        if city.matchesAlternateField(test) { return .alternate }
        return .none
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
    /// Unique ASCII char slots (0-25 for a-z, 26-35 for 0-9) found in the query.
    let asciiChars: [Int]

    init(_ rawQuery: String) {
        let lowered = rawQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = lowered
        var ascii = true
        var charSlotSet = Set<Int>()
        for byte in lowered.utf8 {
            if byte >= 0x80 {
                ascii = false
            } else if byte >= 0x61 && byte <= 0x7A { // a-z
                charSlotSet.insert(Int(byte - 0x61))
            } else if byte >= 0x30 && byte <= 0x39 { // 0-9
                charSlotSet.insert(Int(byte - 0x30) + 26)
            }
        }
        self.isASCII = ascii
        self.asciiChars = Array(charSlotSet)
        let uppered = lowered.uppercased()
        self.isCaseInvariant = !ascii && uppered == lowered
        self.hasComplexCaseMapping = !ascii && lowered.unicodeScalars.count != uppered.unicodeScalars.count
        self.lowerBytes = Array(lowered.utf8)
        self.upperBytes = Array(uppered.utf8)
    }
}
