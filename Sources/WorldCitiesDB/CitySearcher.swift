import Foundation

/// Protocol for city types that support search.
public protocol SearchableCity {
    func matchPrimaryNames(_ fastMatcher: (String) -> Bool, _ foldMatcher: (String) -> Bool) -> Bool
    func matchAlternateNames(_ fastMatcher: (String) -> Bool, _ foldMatcher: (String) -> Bool) -> Bool
}

struct FoldLookupContext {
    let rawTable: UnsafePointer<UInt64>
    let displacements: UnsafePointer<Int32>
    let tableSize: Int
    let bucketCount: Int
    let seed1: UInt32
    let seed2: UInt32
}

struct FieldSpan {
    let start: Int
    let count: Int
}

struct FastFieldRef {
    let offset: Int
    let length: Int
}

struct FoldFieldRef {
    let offset: Int
    let length: Int
}

struct PreparedSearchFields {
    let primaryFast: FieldSpan
    let primaryFold: FieldSpan
    let alternateFast: FieldSpan
    let alternateFold: FieldSpan
}

public struct PackedSearchFields {
    let prepared: [PreparedSearchFields]
    let fieldBytes: [UInt8]
    let fastFieldRefs: [FastFieldRef]
    let foldFieldRefs: [FoldFieldRef]
    let foldStrings: [String]

    var cityCount: Int { prepared.count }

    init(
        prepared: [PreparedSearchFields],
        fieldBytes: [UInt8],
        fastFieldRefs: [FastFieldRef],
        foldFieldRefs: [FoldFieldRef]
    ) {
        self.prepared = prepared
        self.fieldBytes = fieldBytes
        self.fastFieldRefs = fastFieldRefs
        self.foldFieldRefs = foldFieldRefs

        var foldStrings: [String] = []
        foldStrings.reserveCapacity(foldFieldRefs.count)
        for field in foldFieldRefs {
            let range = field.offset..<(field.offset + field.length)
            foldStrings.append(String(decoding: fieldBytes[range], as: UTF8.self))
        }
        self.foldStrings = foldStrings
    }

    static func build<C: SearchableCity>(_ cities: [C]) -> PackedSearchFields {
        var prepared: [PreparedSearchFields] = []
        var fieldBytes: [UInt8] = []
        var fastFieldRefs: [FastFieldRef] = []
        var foldFieldRefs: [FoldFieldRef] = []

        prepared.reserveCapacity(cities.count)
        fastFieldRefs.reserveCapacity(cities.count * 4)
        foldFieldRefs.reserveCapacity(cities.count)

        @inline(__always)
        func appendFieldBytes(_ field: String) -> (offset: Int, length: Int) {
            let offset = fieldBytes.count
            let utf8 = field.utf8
            fieldBytes.append(contentsOf: utf8)
            return (offset, utf8.count)
        }

        for city in cities {
            let primaryFastStart = fastFieldRefs.count
            let primaryFoldStart = foldFieldRefs.count

            forEachPrimarySearchField(city) { field in
                let bytes = appendFieldBytes(field)
                if CasefoldingCache.stringNeedsFoldLookup(field) {
                    foldFieldRefs.append(FoldFieldRef(offset: bytes.offset, length: bytes.length))
                } else {
                    fastFieldRefs.append(FastFieldRef(offset: bytes.offset, length: bytes.length))
                }
            }

            let primaryFast = FieldSpan(start: primaryFastStart, count: fastFieldRefs.count - primaryFastStart)
            let primaryFold = FieldSpan(start: primaryFoldStart, count: foldFieldRefs.count - primaryFoldStart)
            let alternateFastStart = fastFieldRefs.count
            let alternateFoldStart = foldFieldRefs.count

            forEachAlternateSearchField(city) { field in
                let bytes = appendFieldBytes(field)
                if CasefoldingCache.stringNeedsFoldLookup(field) {
                    foldFieldRefs.append(FoldFieldRef(offset: bytes.offset, length: bytes.length))
                } else {
                    fastFieldRefs.append(FastFieldRef(offset: bytes.offset, length: bytes.length))
                }
            }

            let alternateFast = FieldSpan(start: alternateFastStart, count: fastFieldRefs.count - alternateFastStart)
            let alternateFold = FieldSpan(start: alternateFoldStart, count: foldFieldRefs.count - alternateFoldStart)
            prepared.append(PreparedSearchFields(
                primaryFast: primaryFast,
                primaryFold: primaryFold,
                alternateFast: alternateFast,
                alternateFold: alternateFold
            ))
        }

        return PackedSearchFields(
            prepared: prepared,
            fieldBytes: fieldBytes,
            fastFieldRefs: fastFieldRefs,
            foldFieldRefs: foldFieldRefs
        )
    }
}

@inline(__always)
func forEachPrimarySearchField<C: SearchableCity>(_ city: C, _ visit: (String) -> Void) {
    let collector: (String) -> Bool = {
        visit($0)
        return false
    }
    _ = city.matchPrimaryNames(collector, collector)
}

@inline(__always)
func forEachAlternateSearchField<C: SearchableCity>(_ city: C, _ visit: (String) -> Void) {
    let collector: (String) -> Bool = {
        visit($0)
        return false
    }
    _ = city.matchAlternateNames(collector, collector)
}

@inline(__always)
func asciiCaseInsensitiveContains(
    _ hp: UnsafePointer<UInt8>, _ hLen: Int,
    _ np: UnsafePointer<UInt8>, _ nl: Int
) -> Bool {
    guard nl > 0, hLen >= nl else { return nl == 0 }
    let first = np[0]
    let lastStart = hLen &- nl
    var hPos = 0
    while hPos <= lastStart {
        let b0 = hp[hPos]
        let folded0 = (b0 >= 0x41 && b0 <= 0x5A) ? (b0 | 0x20) : b0
        if folded0 != first {
            hPos &+= 1
            continue
        }

        var hi = hPos &+ 1
        var ni = 1
        while ni < nl {
            let b = hp[hi]
            let folded = (b >= 0x41 && b <= 0x5A) ? (b | 0x20) : b
            if folded != np[ni] { break }
            hi &+= 1
            ni &+= 1
        }
        if ni == nl { return true }
        hPos &+= 1
    }
    return false
}

/// Inline fold-and-compare substring search on UTF-8 bytes.
/// ASCII bytes are lowercased on the fly; non-ASCII bytes are folded via the cache.
@inline(__always)
func foldedContains(
    _ hp: UnsafePointer<UInt8>, _ hLen: Int,
    _ np: UnsafePointer<UInt8>, _ nl: Int,
    _ fold: FoldLookupContext
) -> Bool {
    guard nl > 0, hLen >= nl else { return nl == 0 }
    var hPos = 0
    while hPos < hLen {
        var hi = hPos
        var ni = 0

        inner: while ni < nl && hi < hLen {
            let b = hp[hi]
            if b < 0x80 {
                let folded = (b >= 0x41 && b <= 0x5A) ? (b | 0x20) : b
                if folded != np[ni] { break inner }
                hi &+= 1
                ni &+= 1
                continue
            }

            let seqLen: Int
            let scalar: UInt32
            if b < 0xE0 {
                seqLen = 2
                guard hi &+ 1 < hLen else { break inner }
                scalar = (UInt32(b & 0x1F) << 6) | UInt32(hp[hi &+ 1] & 0x3F)
            } else if b < 0xF0 {
                seqLen = 3
                guard hi &+ 2 < hLen else { break inner }
                scalar = (UInt32(b & 0x0F) << 12)
                    | (UInt32(hp[hi &+ 1] & 0x3F) << 6)
                    | UInt32(hp[hi &+ 2] & 0x3F)
            } else {
                seqLen = 4
                guard hi &+ 3 < hLen else { break inner }
                scalar = (UInt32(b & 0x07) << 18)
                    | (UInt32(hp[hi &+ 1] & 0x3F) << 12)
                    | (UInt32(hp[hi &+ 2] & 0x3F) << 6)
                    | UInt32(hp[hi &+ 3] & 0x3F)
            }

            if let raw = lookupFoldRaw(
                scalar,
                fold.rawTable,
                fold.displacements,
                fold.tableSize,
                fold.bucketCount,
                fold.seed1,
                fold.seed2
            ) {
                let entry = FoldEntry(raw: raw)
                let fLen = entry.count
                if ni &+ fLen > nl {
                    // Fold expansion exceeds remaining needle — check partial match.
                    let remaining = nl &- ni
                    for k in 0..<remaining {
                        if entry.byte(k) != np[ni &+ k] { break inner }
                    }
                    ni = nl
                    break inner
                }
                for k in 0..<fLen {
                    if entry.byte(k) != np[ni &+ k] { break inner }
                }
                ni &+= fLen
            } else {
                if ni &+ seqLen > nl { break inner }
                for k in 0..<seqLen {
                    if hp[hi &+ k] != np[ni &+ k] { break inner }
                }
                ni &+= seqLen
            }
            hi &+= seqLen
        }

        if ni >= nl { return true }
        let b = hp[hPos]
        if b < 0x80 { hPos &+= 1 }
        else if b < 0xE0 { hPos &+= 2 }
        else if b < 0xF0 { hPos &+= 3 }
        else { hPos &+= 4 }
    }
    return false
}

/// Searches cities using optional casefold cache and optional search index.
/// - If no casefold cache: falls back to `String.range(of:options:)`.
/// - If no search index: falls back to full scan.
public final class CitySearcher<C: SearchableCity> {
    let cities: [C]
    let packedSearchFields: PackedSearchFields
    public let casefoldingCache: CasefoldingCache?
    public let searchIndex: SearchIndex?

    public init(
        cities: [C],
        casefoldingCache: CasefoldingCache? = nil,
        searchIndex: SearchIndex? = nil,
        packedSearchFields: PackedSearchFields? = nil
    ) {
        self.cities = cities
        if let packedSearchFields, packedSearchFields.cityCount == cities.count {
            self.packedSearchFields = packedSearchFields
        } else {
            self.packedSearchFields = PackedSearchFields.build(cities)
        }
        self.casefoldingCache = casefoldingCache
        if let searchIndex, searchIndex.cityCount == cities.count {
            self.searchIndex = searchIndex
        } else {
            self.searchIndex = nil
        }
    }

    // MARK: - Search

    public func search(query: String, limit: Int = 20) -> [C] {
        let q = Query(query)
        guard !q.trimmed.isEmpty else {
            let n = limit < 0 ? cities.count : min(limit, cities.count)
            return Array(cities.prefix(n))
        }

        let effectiveLimit = limit < 0 ? cities.count : limit
        guard effectiveLimit > 0 else { return [] }

        var primary: [C] = []
        var alternate: [C] = []
        primary.reserveCapacity(min(effectiveLimit, 64))
        alternate.reserveCapacity(min(effectiveLimit, 64))

        let appendMatch: (Int, Bool) -> Bool = { idx, isPrimary in
            if isPrimary {
                if primary.count < effectiveLimit { primary.append(self.cities[idx]) }
                // We can stop as soon as we have enough primary matches because
                // primary results always rank ahead of alternates.
                return primary.count < effectiveLimit
            } else if alternate.count < effectiveLimit {
                alternate.append(self.cities[idx])
            }
            return true
        }

        if let searchIndex {
            guard let bitmap = searchIndex.candidates(for: q.foldedScalars) else { return [] }
            scanBitmap(bitmap, query: q, body: appendMatch)
        } else {
            scanAll(q, body: appendMatch)
        }

        if primary.count >= effectiveLimit {
            return Array(primary.prefix(effectiveLimit))
        }

        let remaining = effectiveLimit - primary.count
        if remaining > 0 {
            primary.append(contentsOf: alternate.prefix(remaining))
        }
        return primary
    }

    public func newSearch() -> SearchContext<C> {
        SearchContext(searcher: self)
    }

    // MARK: - Internals

    enum MatchKind {
        case primary
        case alternate
        case none
    }

    @inline(__always)
    private func matchesFastSpan(
        _ span: FieldSpan,
        _ bytes: UnsafePointer<UInt8>,
        _ np: UnsafePointer<UInt8>,
        _ nl: Int
    ) -> Bool {
        let end = span.start + span.count
        guard span.count > 0 else { return false }
        for index in span.start..<end {
            let field = packedSearchFields.fastFieldRefs[index]
            if asciiCaseInsensitiveContains(bytes.advanced(by: field.offset), field.length, np, nl) {
                return true
            }
        }
        return false
    }

    @inline(__always)
    private func matchesFoldSpanWithRange(
        _ span: FieldSpan,
        _ query: Query
    ) -> Bool {
        let end = span.start + span.count
        guard span.count > 0 else { return false }
        for index in span.start..<end {
            if packedSearchFields.foldStrings[index]
                .folding(options: searchFoldOptions, locale: nil)
                .range(of: query.folded, options: .literal) != nil {
                return true
            }
        }
        return false
    }

    @inline(__always)
    private func matchesFoldSpanWithCache(
        _ span: FieldSpan,
        _ bytes: UnsafePointer<UInt8>,
        _ np: UnsafePointer<UInt8>,
        _ nl: Int,
        _ fold: FoldLookupContext
    ) -> Bool {
        let end = span.start + span.count
        guard span.count > 0 else { return false }
        for index in span.start..<end {
            let field = packedSearchFields.foldFieldRefs[index]
            if foldedContains(bytes.advanced(by: field.offset), field.length, np, nl, fold) {
                return true
            }
        }
        return false
    }

    @inline(__always)
    private func classifyPreparedCityWithRange(
        _ i: Int,
        _ bytes: UnsafePointer<UInt8>,
        _ np: UnsafePointer<UInt8>,
        _ nl: Int,
        _ query: Query
    ) -> MatchKind {
        let fields = packedSearchFields.prepared[i]

        if matchesFastSpan(fields.primaryFast, bytes, np, nl) || matchesFoldSpanWithRange(fields.primaryFold, query) {
            return .primary
        }
        if matchesFastSpan(fields.alternateFast, bytes, np, nl) || matchesFoldSpanWithRange(fields.alternateFold, query) {
            return .alternate
        }
        return .none
    }

    @inline(__always)
    private func classifyPreparedCityWithCache(
        _ i: Int,
        _ bytes: UnsafePointer<UInt8>,
        _ np: UnsafePointer<UInt8>,
        _ nl: Int,
        _ fold: FoldLookupContext
    ) -> MatchKind {
        let fields = packedSearchFields.prepared[i]

        if matchesFastSpan(fields.primaryFast, bytes, np, nl)
            || matchesFoldSpanWithCache(fields.primaryFold, bytes, np, nl, fold) {
            return .primary
        }
        if matchesFastSpan(fields.alternateFast, bytes, np, nl)
            || matchesFoldSpanWithCache(fields.alternateFold, bytes, np, nl, fold) {
            return .alternate
        }
        return .none
    }

    private func withFoldContext(
        _ needle: [UInt8],
        _ body: (UnsafePointer<UInt8>, Int, FoldLookupContext) -> Void
    ) {
        guard let casefoldingCache else { return }
        let rawTable = casefoldingCache.rawTable
        let displacements = casefoldingCache.displacements
        needle.withUnsafeBufferPointer { nBuf in
            guard let np = nBuf.baseAddress, nBuf.count > 0 else { return }
            if rawTable.isEmpty || displacements.isEmpty {
                var rawSentinel: UInt64 = 0
                var displacementSentinel: Int32 = 0
                withUnsafePointer(to: &rawSentinel) { rawPtr in
                    withUnsafePointer(to: &displacementSentinel) { displacementPtr in
                        let context = FoldLookupContext(
                            rawTable: rawPtr,
                            displacements: displacementPtr,
                            tableSize: 0,
                            bucketCount: 0,
                            seed1: casefoldingCache.seed1,
                            seed2: casefoldingCache.seed2
                        )
                        body(np, nBuf.count, context)
                    }
                }
                return
            }

            rawTable.withUnsafeBufferPointer { tableBuf in
                displacements.withUnsafeBufferPointer { displacementBuf in
                    let context = FoldLookupContext(
                        rawTable: tableBuf.baseAddress!,
                        displacements: displacementBuf.baseAddress!,
                        tableSize: tableBuf.count,
                        bucketCount: displacementBuf.count,
                        seed1: casefoldingCache.seed1,
                        seed2: casefoldingCache.seed2
                    )
                    body(np, nBuf.count, context)
                }
            }
        }
    }

    func scanAll(_ query: Query, body: (Int, Bool) -> Bool) {
        if casefoldingCache == nil {
            packedSearchFields.fieldBytes.withUnsafeBufferPointer { fieldBuf in
                guard let bytes = fieldBuf.baseAddress else { return }
                query.foldedBytes.withUnsafeBufferPointer { needleBuf in
                    guard let np = needleBuf.baseAddress else { return }
                    for i in 0..<cities.count {
                        switch classifyPreparedCityWithRange(i, bytes, np, needleBuf.count, query) {
                        case .primary:
                            if !body(i, true) { return }
                        case .alternate:
                            if !body(i, false) { return }
                        case .none: break
                        }
                    }
                }
            }
            return
        }

        withFoldContext(query.foldedBytes) { np, nl, fold in
            packedSearchFields.fieldBytes.withUnsafeBufferPointer { fieldBuf in
                guard let bytes = fieldBuf.baseAddress else { return }
                for i in 0..<cities.count {
                    switch classifyPreparedCityWithCache(i, bytes, np, nl, fold) {
                    case .primary:
                        if !body(i, true) { return }
                    case .alternate:
                        if !body(i, false) { return }
                    case .none: break
                    }
                }
            }
        }
    }

    func scanBitmap(_ bitmap: [UInt64], query: Query, body: (Int, Bool) -> Bool) {
        if casefoldingCache == nil {
            packedSearchFields.fieldBytes.withUnsafeBufferPointer { fieldBuf in
                guard let bytes = fieldBuf.baseAddress else { return }
                query.foldedBytes.withUnsafeBufferPointer { needleBuf in
                    guard let np = needleBuf.baseAddress else { return }
                    let wordCount = bitmap.count
                    for w in 0..<wordCount {
                        var bits = bitmap[w]
                        while bits != 0 {
                            let bit = bits.trailingZeroBitCount
                            bits &= bits &- 1
                            let i = w * 64 + bit
                            switch classifyPreparedCityWithRange(i, bytes, np, needleBuf.count, query) {
                            case .primary:
                                if !body(i, true) { return }
                            case .alternate:
                                if !body(i, false) { return }
                            case .none: break
                            }
                        }
                    }
                }
            }
            return
        }

        withFoldContext(query.foldedBytes) { np, nl, fold in
            packedSearchFields.fieldBytes.withUnsafeBufferPointer { fieldBuf in
                guard let bytes = fieldBuf.baseAddress else { return }
                let wordCount = bitmap.count
                for w in 0..<wordCount {
                    var bits = bitmap[w]
                    while bits != 0 {
                        let bit = bits.trailingZeroBitCount
                        bits &= bits &- 1
                        let i = w * 64 + bit
                        switch classifyPreparedCityWithCache(i, bytes, np, nl, fold) {
                        case .primary:
                            if !body(i, true) { return }
                        case .alternate:
                            if !body(i, false) { return }
                        case .none: break
                        }
                    }
                }
            }
        }
    }

    func scanIndices(_ indices: [Int32], query: Query, body: (Int, Bool) -> Bool) {
        if casefoldingCache == nil {
            packedSearchFields.fieldBytes.withUnsafeBufferPointer { fieldBuf in
                guard let bytes = fieldBuf.baseAddress else { return }
                query.foldedBytes.withUnsafeBufferPointer { needleBuf in
                    guard let np = needleBuf.baseAddress else { return }
                    for idx in indices {
                        let i = Int(idx)
                        switch classifyPreparedCityWithRange(i, bytes, np, needleBuf.count, query) {
                        case .primary:
                            if !body(i, true) { return }
                        case .alternate:
                            if !body(i, false) { return }
                        case .none: break
                        }
                    }
                }
            }
            return
        }

        withFoldContext(query.foldedBytes) { np, nl, fold in
            packedSearchFields.fieldBytes.withUnsafeBufferPointer { fieldBuf in
                guard let bytes = fieldBuf.baseAddress else { return }
                for idx in indices {
                    let i = Int(idx)
                    switch classifyPreparedCityWithCache(i, bytes, np, nl, fold) {
                    case .primary:
                        if !body(i, true) { return }
                    case .alternate:
                        if !body(i, false) { return }
                    case .none: break
                    }
                }
            }
        }
    }

    func scanMergedIndices(_ lhs: [Int32], _ rhs: [Int32], query: Query, body: (Int, Bool) -> Bool) {
        if casefoldingCache == nil {
            packedSearchFields.fieldBytes.withUnsafeBufferPointer { fieldBuf in
                guard let bytes = fieldBuf.baseAddress else { return }
                query.foldedBytes.withUnsafeBufferPointer { needleBuf in
                    guard let np = needleBuf.baseAddress else { return }
                    var li = 0
                    var ri = 0
                    while li < lhs.count || ri < rhs.count {
                        let idx: Int32
                        if ri >= rhs.count || (li < lhs.count && lhs[li] <= rhs[ri]) {
                            idx = lhs[li]
                            li &+= 1
                        } else {
                            idx = rhs[ri]
                            ri &+= 1
                        }

                        let i = Int(idx)
                        switch classifyPreparedCityWithRange(i, bytes, np, needleBuf.count, query) {
                        case .primary:
                            if !body(i, true) { return }
                        case .alternate:
                            if !body(i, false) { return }
                        case .none: break
                        }
                    }
                }
            }
            return
        }

        withFoldContext(query.foldedBytes) { np, nl, fold in
            packedSearchFields.fieldBytes.withUnsafeBufferPointer { fieldBuf in
                guard let bytes = fieldBuf.baseAddress else { return }
                var li = 0
                var ri = 0
                while li < lhs.count || ri < rhs.count {
                    let idx: Int32
                    if ri >= rhs.count || (li < lhs.count && lhs[li] <= rhs[ri]) {
                        idx = lhs[li]
                        li &+= 1
                    } else {
                        idx = rhs[ri]
                        ri &+= 1
                    }

                    let i = Int(idx)
                    switch classifyPreparedCityWithCache(i, bytes, np, nl, fold) {
                    case .primary:
                        if !body(i, true) { return }
                    case .alternate:
                        if !body(i, false) { return }
                    case .none: break
                    }
                }
            }
        }
    }
}

// MARK: - SearchContext

public final class SearchContext<C: SearchableCity> {
    private let searcher: CitySearcher<C>
    private var cities: [C] { searcher.cities }

    private var lastQuery: Query?
    private var lastPrimaryMatches: [Int32] = []
    private var lastAlternateMatches: [Int32] = []

    init(searcher: CitySearcher<C>) {
        self.searcher = searcher
    }

    public func update(query rawQuery: String) {
        let query = Query(rawQuery)
        guard !query.trimmed.isEmpty else {
            lastPrimaryMatches.removeAll(keepingCapacity: true)
            lastAlternateMatches.removeAll(keepingCapacity: true)
            lastQuery = query
            return
        }

        if let prev = lastQuery, query.foldedBytes == prev.foldedBytes { return }

        if let prev = lastQuery, !prev.foldedBytes.isEmpty,
           query.foldedBytes.starts(with: prev.foldedBytes) {
            narrowMatches(query)
        } else {
            fullScan(query)
        }
        lastQuery = query
    }

    public func results(limit: Int = 20) -> [C] {
        guard let lastQuery, !lastQuery.trimmed.isEmpty else {
            let n = limit < 0 ? cities.count : min(limit, cities.count)
            return Array(cities.prefix(n))
        }
        let total = lastPrimaryMatches.count + lastAlternateMatches.count
        let n = limit < 0 ? total : min(limit, total)
        guard n > 0 else { return [] }

        var results: [C] = []
        results.reserveCapacity(n)
        for idx in lastPrimaryMatches.prefix(n) {
            results.append(cities[Int(idx)])
        }
        let remaining = n - results.count
        if remaining > 0 {
            for idx in lastAlternateMatches.prefix(remaining) {
                results.append(cities[Int(idx)])
            }
        }
        return results
    }

    private func fullScan(_ query: Query) {
        var primary: [Int32] = []
        var alternate: [Int32] = []

        if let searchIndex = searcher.searchIndex {
            guard let bitmap = searchIndex.candidates(for: query.foldedScalars) else {
                lastPrimaryMatches = primary
                lastAlternateMatches = alternate
                return
            }
            searcher.scanBitmap(bitmap, query: query) { idx, isPrimary in
                if isPrimary { primary.append(Int32(idx)) }
                else { alternate.append(Int32(idx)) }
                return true
            }
        } else {
            searcher.scanAll(query) { idx, isPrimary in
                if isPrimary { primary.append(Int32(idx)) }
                else { alternate.append(Int32(idx)) }
                return true
            }
        }

        lastPrimaryMatches = primary
        lastAlternateMatches = alternate
    }

    private func narrowMatches(_ query: Query) {
        var nextPrimary: [Int32] = []
        var nextAlternate: [Int32] = []
        nextPrimary.reserveCapacity(lastPrimaryMatches.count)
        nextAlternate.reserveCapacity(lastAlternateMatches.count)

        searcher.scanMergedIndices(lastPrimaryMatches, lastAlternateMatches, query: query) { idx, isPrimary in
            if isPrimary { nextPrimary.append(Int32(idx)) }
            else { nextAlternate.append(Int32(idx)) }
            return true
        }

        lastPrimaryMatches = nextPrimary
        lastAlternateMatches = nextAlternate
    }
}

// MARK: - Query

struct Query {
    let trimmed: String
    let folded: String
    let foldedBytes: [UInt8]
    let foldedScalars: [UInt32]

    init(_ rawQuery: String) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trimmed = trimmed
        let folded = trimmed.folding(options: searchFoldOptions, locale: nil)
        self.folded = folded
        let foldedBytes = Array(folded.utf8)
        self.foldedBytes = foldedBytes
        self.foldedScalars = folded.unicodeScalars.map { $0.value }
    }
}
