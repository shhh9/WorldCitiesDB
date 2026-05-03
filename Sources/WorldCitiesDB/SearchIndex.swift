import Foundation

/// Per-scalar search index: maps each unique folded Unicode scalar to the set of cities containing it.
/// Hybrid: bitmap for frequent scalars, varint deltas for rare ones.
/// All data packed into two contiguous buffers (bitmaps + varints) for low overhead.
public struct SearchIndex {
    public let cityCount: Int
    let wordCount: Int

    /// Contiguous storage for all bitmap entries.
    let bitmapBuf: [UInt64]
    /// Contiguous storage for all varint entries.
    let varintBuf: [UInt8]

    /// Entry ref: offset into `bitmapBuf` or `varintBuf`, plus length.
    /// High bit of `packed` = isBitmap. Lower 31 bits = length.
    struct Ref {
        let offset: UInt32
        let packed: UInt32

        static let empty = Ref(offset: 0, packed: 0)

        var isEmpty: Bool { packed == 0 }
        var isBitmap: Bool { packed & 0x8000_0000 != 0 }
        var length: Int { Int(packed & 0x7FFF_FFFF) }

        static func bitmap(offset: UInt32, wordCount: UInt32) -> Ref {
            Ref(offset: offset, packed: 0x8000_0000 | wordCount)
        }

        static func varint(offset: UInt32, byteCount: UInt32) -> Ref {
            Ref(offset: offset, packed: byteCount)
        }
    }

    /// Direct lookup for ASCII scalars 0..<128.
    let asciiRefs: [Ref]
    let asciiCounts: [UInt32]

    /// Sorted non-ASCII scalar values.
    let nonAsciiKeys: [UInt32]
    let nonAsciiRefs: [Ref]
    let nonAsciiCounts: [UInt32]

    init(scalarSets: inout [UInt32: [Int32]], cityCount: Int) {
        self.cityCount = cityCount
        let bitmapThreshold = (cityCount + 7) / 8
        let wc = (cityCount + 63) / 64
        self.wordCount = wc

        var bitmapBuf = [UInt64]()
        var varintBuf = [UInt8]()

        func encode(_ indices: [Int32]) -> (Ref, UInt32) {
            let cityFreq = UInt32(indices.count)

            let varintStart = varintBuf.count
            var prev: Int32 = 0
            for idx in indices {
                var delta = UInt32(idx - prev)
                prev = idx
                while delta >= 0x80 {
                    varintBuf.append(UInt8(delta & 0x7F) | 0x80)
                    delta >>= 7
                }
                varintBuf.append(UInt8(delta))
            }
            let varintLen = varintBuf.count - varintStart

            if varintLen <= bitmapThreshold {
                return (.varint(offset: UInt32(varintStart), byteCount: UInt32(varintLen)), cityFreq)
            }

            varintBuf.removeSubrange(varintStart...)
            let bitmapStart = bitmapBuf.count
            bitmapBuf.append(contentsOf: repeatElement(UInt64(0), count: wc))
            for idx in indices {
                let i = Int(idx)
                bitmapBuf[bitmapStart + (i >> 6)] |= 1 << (i & 63)
            }
            return (.bitmap(offset: UInt32(bitmapStart), wordCount: UInt32(wc)), cityFreq)
        }

        var asciiRefs = [Ref](repeating: .empty, count: 128)
        var asciiCounts = [UInt32](repeating: 0, count: 128)
        for sv in UInt32(0)..<128 {
            if let indices = scalarSets.removeValue(forKey: sv) {
                let (ref, cityFreq) = encode(indices)
                asciiRefs[Int(sv)] = ref
                asciiCounts[Int(sv)] = cityFreq
            }
        }
        self.asciiRefs = asciiRefs
        self.asciiCounts = asciiCounts

        let sortedNonAscii = scalarSets.sorted { $0.key < $1.key }
        var naKeys = [UInt32]()
        var naRefs = [Ref]()
        var naCounts = [UInt32]()
        naKeys.reserveCapacity(sortedNonAscii.count)
        naRefs.reserveCapacity(sortedNonAscii.count)
        naCounts.reserveCapacity(sortedNonAscii.count)

        for (key, indices) in sortedNonAscii {
            let (ref, cityFreq) = encode(indices)
            naKeys.append(key)
            naRefs.append(ref)
            naCounts.append(cityFreq)
        }
        self.nonAsciiKeys = naKeys
        self.nonAsciiRefs = naRefs
        self.nonAsciiCounts = naCounts

        self.bitmapBuf = bitmapBuf
        self.varintBuf = varintBuf
    }

    init(
        cityCount: Int,
        wordCount: Int,
        bitmapBuf: [UInt64],
        varintBuf: [UInt8],
        asciiRefs: [Ref],
        asciiCounts: [UInt32],
        nonAsciiKeys: [UInt32],
        nonAsciiRefs: [Ref],
        nonAsciiCounts: [UInt32]
    ) {
        self.cityCount = cityCount
        self.wordCount = wordCount
        self.bitmapBuf = bitmapBuf
        self.varintBuf = varintBuf
        self.asciiRefs = asciiRefs
        self.asciiCounts = asciiCounts
        self.nonAsciiKeys = nonAsciiKeys
        self.nonAsciiRefs = nonAsciiRefs
        self.nonAsciiCounts = nonAsciiCounts
    }

    public static func build<C: SearchableCity>(cities: [C], casefoldingCache: CasefoldingCache) -> SearchIndex {
        var scalarPostings: [UInt32: [Int32]] = Dictionary(minimumCapacity: 8192)
        var citySeenScalars = Set<UInt32>(minimumCapacity: 256)
        let foldScalarMap = casefoldingCache.scalarExpansionMap()

        for (cityIndex, city) in cities.enumerated() {
            citySeenScalars.removeAll(keepingCapacity: true)
            let encodedCityIndex = Int32(cityIndex)

            func addScalar(_ scalar: UInt32) {
                if citySeenScalars.insert(scalar).inserted {
                    scalarPostings[scalar, default: []].append(encodedCityIndex)
                }
            }

            forEachSearchField(city) { text in
                var value = text
                value.withUTF8 { buf in
                    guard let bytes = buf.baseAddress else { return }
                    var pos = 0
                    while pos < buf.count {
                        let b0 = bytes[pos]
                        if b0 < 0x80 {
                            let folded = (b0 >= 0x41 && b0 <= 0x5A) ? UInt32(b0 | 0x20) : UInt32(b0)
                            addScalar(folded)
                            pos &+= 1
                            continue
                        }

                        guard let decoded = decodeUTF8Scalar(bytes, buf.count, pos) else {
                            pos &+= 1
                            continue
                        }
                        let scalar = decoded.scalar
                        pos &+= decoded.sequenceLength

                        if let expanded = foldScalarMap[scalar] {
                            for foldedScalar in expanded {
                                addScalar(foldedScalar)
                            }
                        } else {
                            addScalar(scalar)
                        }
                    }
                }
            }
        }

        var mutablePostings = scalarPostings
        return SearchIndex(scalarSets: &mutablePostings, cityCount: cities.count)
    }

    /// Returns (asciiBytes, nonAsciiBytes, nonAsciiCount) for memory reporting.
    public func memorySummary() -> (Int, Int, Int) {
        var asciiBytes = 0
        for ref in asciiRefs where !ref.isEmpty {
            asciiBytes += ref.isBitmap ? ref.length * 8 : ref.length
        }

        var nonAsciiBytes = nonAsciiKeys.count * 4
        nonAsciiBytes += nonAsciiRefs.count * 8
        for ref in nonAsciiRefs {
            nonAsciiBytes += ref.isBitmap ? ref.length * 8 : ref.length
        }

        return (asciiBytes, nonAsciiBytes, nonAsciiKeys.count)
    }

    /// Returns candidate bitmap for all scalars in the folded query (AND intersection).
    func candidates(for foldedScalars: [UInt32]) -> [UInt64]? {
        let wc = self.wordCount

        struct Term {
            let ref: Ref
            let cityFreq: UInt32
        }

        var seenBuf: (UInt32,UInt32,UInt32,UInt32, UInt32,UInt32,UInt32,UInt32,
                      UInt32,UInt32,UInt32,UInt32, UInt32,UInt32,UInt32,UInt32) =
            (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)
        var seenCount = 0
        var seenOverflow: Set<UInt32>? = nil
        var terms: [Term] = []
        terms.reserveCapacity(min(16, foldedScalars.count))

        for sv in foldedScalars {
            let isDupSmall = withUnsafeBytes(of: &seenBuf) { raw in
                let p = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
                for j in 0..<seenCount where p[j] == sv { return true }
                return false
            }
            if isDupSmall { continue }

            if seenCount < 16 {
                withUnsafeMutableBytes(of: &seenBuf) { raw in
                    raw.baseAddress!.assumingMemoryBound(to: UInt32.self)[seenCount] = sv
                }
                seenCount += 1
            } else {
                if seenOverflow == nil {
                    var seeded = Set<UInt32>(minimumCapacity: max(32, foldedScalars.count))
                    withUnsafeBytes(of: &seenBuf) { raw in
                        let p = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
                        for j in 0..<seenCount { seeded.insert(p[j]) }
                    }
                    seenOverflow = seeded
                }
                if !(seenOverflow!.insert(sv).inserted) { continue }
            }

            if sv < 128 {
                let idx = Int(sv)
                let ref = asciiRefs[idx]
                guard !ref.isEmpty else { return nil }
                terms.append(Term(ref: ref, cityFreq: asciiCounts[idx]))
            } else {
                var lo = 0
                var hi = nonAsciiKeys.count - 1
                var found = -1
                while lo <= hi {
                    let mid = (lo + hi) >> 1
                    let mv = nonAsciiKeys[mid]
                    if mv == sv { found = mid; break }
                    if mv < sv { lo = mid + 1 } else { hi = mid - 1 }
                }
                guard found >= 0 else { return nil }
                terms.append(Term(ref: nonAsciiRefs[found], cityFreq: nonAsciiCounts[found]))
            }
        }

        if terms.count > 1 {
            terms.sort { $0.cityFreq < $1.cityFreq }
        }

        guard let firstTerm = terms.first else { return nil }

        func decodeVarintIndices(_ ref: Ref) -> [Int32] {
            var out: [Int32] = []
            out.reserveCapacity(min(cityCount, max(16, Int(ref.length))))
            var idx: Int32 = 0
            var pos = Int(ref.offset)
            let end = pos + ref.length
            while pos < end {
                var delta: UInt32 = 0
                var shift: UInt32 = 0
                while true {
                    let byte = varintBuf[pos]
                    pos &+= 1
                    delta |= UInt32(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { break }
                    shift &+= 7
                }
                idx &+= Int32(delta)
                out.append(idx)
            }
            return out
        }

        func intersectSortedInPlaceWithVarint(_ lhs: inout [Int32], _ ref: Ref) -> Bool {
            guard !lhs.isEmpty else { return false }
            var li = 0
            var write = 0
            var rhs: Int32 = 0
            var pos = Int(ref.offset)
            let end = pos + ref.length

            while li < lhs.count && pos < end {
                var delta: UInt32 = 0
                var shift: UInt32 = 0
                while true {
                    let byte = varintBuf[pos]
                    pos &+= 1
                    delta |= UInt32(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { break }
                    shift &+= 7
                }
                rhs &+= Int32(delta)

                while li < lhs.count && lhs[li] < rhs {
                    li &+= 1
                }
                if li == lhs.count { break }
                if lhs[li] == rhs {
                    lhs[write] = rhs
                    write &+= 1
                    li &+= 1
                }
            }

            if write < lhs.count {
                lhs.removeSubrange(write..<lhs.count)
            }
            return !lhs.isEmpty
        }

        func filterSortedInPlaceWithBitmap(_ lhs: inout [Int32], _ ref: Ref) -> Bool {
            guard !lhs.isEmpty else { return false }
            let off = Int(ref.offset)
            var write = 0
            for read in 0..<lhs.count {
                let idx = lhs[read]
                let i = Int(idx)
                let bit = UInt64(1) << UInt64(i & 63)
                if bitmapBuf[off + (i >> 6)] & bit != 0 {
                    lhs[write] = idx
                    write &+= 1
                }
            }
            if write < lhs.count {
                lhs.removeSubrange(write..<lhs.count)
            }
            return !lhs.isEmpty
        }

        enum CandidateState {
            case bitmap([UInt64], [Int])
            case indices([Int32])
        }

        var state: CandidateState
        if firstTerm.ref.isBitmap {
            let off = Int(firstTerm.ref.offset)
            var words = [UInt64](repeating: 0, count: wc)
            var activeWords: [Int] = []
            activeWords.reserveCapacity(wc)
            for w in 0..<wc {
                let v = bitmapBuf[off + w]
                words[w] = v
                if v != 0 { activeWords.append(w) }
            }
            guard !activeWords.isEmpty else { return nil }
            state = .bitmap(words, activeWords)
        } else {
            let indices = decodeVarintIndices(firstTerm.ref)
            guard !indices.isEmpty else { return nil }
            state = .indices(indices)
        }

        if terms.count > 1 {
            for term in terms.dropFirst() {
                let ref = term.ref
                switch state {
                case .indices(var current):
                    let hasCandidates = ref.isBitmap
                        ? filterSortedInPlaceWithBitmap(&current, ref)
                        : intersectSortedInPlaceWithVarint(&current, ref)
                    guard hasCandidates else { return nil }
                    state = .indices(current)

                case .bitmap(var words, let activeWords):
                    if ref.isBitmap {
                        let off = Int(ref.offset)
                        var nextActiveWords: [Int] = []
                        nextActiveWords.reserveCapacity(activeWords.count)
                        for w in activeWords {
                            let next = words[w] & bitmapBuf[off + w]
                            words[w] = next
                            if next != 0 { nextActiveWords.append(w) }
                        }
                        guard !nextActiveWords.isEmpty else { return nil }
                        state = .bitmap(words, nextActiveWords)
                    } else {
                        let off = Int(ref.offset)
                        let end = off + ref.length
                        var idx: Int32 = 0
                        var pos = off
                        var next: [Int32] = []
                        next.reserveCapacity(min(cityCount, max(16, Int(ref.length))))
                        while pos < end {
                            var delta: UInt32 = 0
                            var shift: UInt32 = 0
                            while true {
                                let byte = varintBuf[pos]
                                pos &+= 1
                                delta |= UInt32(byte & 0x7F) << shift
                                if byte & 0x80 == 0 { break }
                                shift &+= 7
                            }
                            idx &+= Int32(delta)
                            let i = Int(idx)
                            let bit = UInt64(1) << UInt64(i & 63)
                            if words[i >> 6] & bit != 0 {
                                next.append(idx)
                            }
                        }
                        guard !next.isEmpty else { return nil }
                        state = .indices(next)
                    }
                }
            }
        }

        switch state {
        case .bitmap(let words, _):
            return words
        case .indices(let indices):
            var result = [UInt64](repeating: 0, count: wc)
            for idx in indices {
                let i = Int(idx)
                result[i >> 6] |= UInt64(1) << UInt64(i & 63)
            }
            return result
        }
    }
}
