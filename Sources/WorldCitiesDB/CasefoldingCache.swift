import Foundation

let searchFoldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

/// Maps a non-ASCII scalar to its folded UTF-8 bytes, packed into a single UInt64.
/// Layout: bits 63-60 = count (0-15), bits 59-32 = source scalar (28 bits), bits 31-0 = folded UTF-8 bytes.
public struct FoldEntry {
    public let raw: UInt64

    @inline(__always) public var count: Int { Int(raw >> 60) }
    @inline(__always) public var from: UInt32 { UInt32((raw >> 32) & 0x0FFF_FFFF) }
    @inline(__always) public func byte(_ k: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: raw &>> (k &* 8))
    }

    public init(raw: UInt64) { self.raw = raw }

    public init(from: UInt32, foldedUTF8: some Collection<UInt8>) {
        precondition(foldedUTF8.count <= 4, "Folded UTF-8 exceeds 4 bytes")
        precondition(from <= 0x0FFF_FFFF, "Scalar exceeds 28 bits")
        var packed: UInt64 = UInt64(foldedUTF8.count) << 60
        packed |= UInt64(from) << 32
        for (k, b) in foldedUTF8.enumerated() {
            packed |= UInt64(b) << (k * 8)
        }
        self.raw = packed
    }
}

@inline(__always)
func decodeUTF8Scalar(
    _ bytes: UnsafePointer<UInt8>,
    _ length: Int,
    _ start: Int
) -> (scalar: UInt32, sequenceLength: Int)? {
    guard start < length else { return nil }
    let b0 = bytes[start]
    if b0 < 0x80 {
        return (UInt32(b0), 1)
    }
    if b0 < 0xE0 {
        guard start &+ 1 < length else { return nil }
        let scalar = (UInt32(b0 & 0x1F) << 6) | UInt32(bytes[start &+ 1] & 0x3F)
        return (scalar, 2)
    }
    if b0 < 0xF0 {
        guard start &+ 2 < length else { return nil }
        let scalar = (UInt32(b0 & 0x0F) << 12)
            | (UInt32(bytes[start &+ 1] & 0x3F) << 6)
            | UInt32(bytes[start &+ 2] & 0x3F)
        return (scalar, 3)
    }
    guard start &+ 3 < length else { return nil }
    let scalar = (UInt32(b0 & 0x07) << 18)
        | (UInt32(bytes[start &+ 1] & 0x3F) << 12)
        | (UInt32(bytes[start &+ 2] & 0x3F) << 6)
        | UInt32(bytes[start &+ 3] & 0x3F)
    return (scalar, 4)
}

@inline(__always)
func forEachSearchField<C: SearchableCity>(_ city: C, _ visit: (String) -> Void) {
    let everyField: (String) -> Bool = { visit($0); return false }
    _ = city.matchPrimaryNames(everyField, everyField)
    _ = city.matchAlternateNames(everyField, everyField)
}

@inline(__always)
func foldHashBucket(_ key: UInt32, _ seed: UInt32, _ bucketCount: Int) -> Int {
    Int(((key &* (seed | 1)) &+ seed) % UInt32(bucketCount))
}

@inline(__always)
func foldHashSlot(_ key: UInt32, _ seed: UInt32, _ displacement: UInt32, _ tableSize: Int) -> Int {
    Int((((key &+ displacement) &* (seed | 1)) &+ seed) % UInt32(tableSize))
}

@inline(__always)
func lookupFoldRaw(
    _ scalar: UInt32,
    _ table: UnsafePointer<UInt64>,
    _ displacements: UnsafePointer<Int32>,
    _ tableSize: Int,
    _ bucketCount: Int,
    _ seed1: UInt32,
    _ seed2: UInt32
) -> UInt64? {
    guard tableSize > 0, bucketCount > 0 else { return nil }
    let bucket = foldHashBucket(scalar, seed1, bucketCount)
    let encoded = displacements[bucket]
    guard encoded != 0 else { return nil }

    let index: Int
    if encoded < 0 {
        index = Int(-encoded - 1)
    } else {
        index = foldHashSlot(scalar, seed2, UInt32(encoded - 1), tableSize)
    }

    let raw = table[index]
    return UInt32((raw >> 32) & 0x0FFF_FFFF) == scalar ? raw : nil
}

private struct FoldSeedGenerator {
    private var state: UInt32

    init(seed: UInt32) {
        self.state = seed | 1
    }

    mutating func next() -> UInt32 {
        state = state &* 1_664_525 &+ 1_013_904_223
        return state | 1
    }
}

/// Prebuilt per-scalar casefold expansion cache used by search matching and index construction.
public struct CasefoldingCache {
    public let rawTable: [UInt64]
    let displacements: [Int32]
    let seed1: UInt32
    let seed2: UInt32
    let needsFoldBits: [UInt64]

    public var entryCount: Int { rawTable.count }
    public var rawTableBytes: Int { rawTable.count * MemoryLayout<UInt64>.stride }
    public var displacementBytes: Int { displacements.count * MemoryLayout<Int32>.stride }
    public var needsFoldBitsBytes: Int { needsFoldBits.count * MemoryLayout<UInt64>.stride }
    public var totalBytes: Int { rawTableBytes + displacementBytes + needsFoldBitsBytes }

    private static let unicodeNeedsFoldBits: [UInt64] = buildUnicodeNeedsFoldBits()

    public static func stringNeedsFoldLookup(_ value: String) -> Bool {
        var copy = value
        return copy.withUTF8 { utf8 in
            guard let base = utf8.baseAddress else { return false }
            return utf8NeedsFoldLookup(base, count: utf8.count, bits: unicodeNeedsFoldBits)
        }
    }

    public static func utf8ContainsNonIdentityFold(_ utf8: some Collection<UInt8>) -> Bool {
        let bytes = Array(utf8)
        return bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return false }
            return utf8NeedsFoldLookup(base, count: buf.count, bits: unicodeNeedsFoldBits)
        }
    }

    /// Preserves the previous public surface for diagnostics and benchmarks.
    public var entries: [FoldEntry] {
        rawTable.map(FoldEntry.init(raw:)).sorted { $0.from < $1.from }
    }

    public init(entries: [FoldEntry]) {
        self = Self.buildLookup(entries)
    }

    init(rawTable: [UInt64], displacements: [Int32], seed1: UInt32, seed2: UInt32, needsFoldBits: [UInt64]? = nil) {
        self.rawTable = rawTable
        self.displacements = displacements
        self.seed1 = seed1
        self.seed2 = seed2
        self.needsFoldBits = needsFoldBits ?? Self.makeNeedsFoldBits(rawTable: rawTable)
    }

    public static func build<C: SearchableCity>(cities: [C]) -> CasefoldingCache {
        var discovered = Set<UInt32>(minimumCapacity: 1024)
        var entries: [FoldEntry] = []
        entries.reserveCapacity(1024)

        for city in cities {
            forEachSearchField(city) { text in
                var value = text
                value.withUTF8 { utf8 in
                    guard let bytes = utf8.baseAddress else { return }
                    var pos = 0
                    while pos < utf8.count {
                        let b0 = bytes[pos]
                        if b0 < 0x80 {
                            pos &+= 1
                            continue
                        }

                        guard let decoded = decodeUTF8Scalar(bytes, utf8.count, pos) else {
                            pos &+= 1
                            continue
                        }
                        pos &+= decoded.sequenceLength

                        guard discovered.insert(decoded.scalar).inserted else { continue }
                        guard let unicodeScalar = UnicodeScalar(decoded.scalar) else { continue }

                        let source = String(unicodeScalar)
                        let foldedString = source.folding(options: searchFoldOptions, locale: nil)
                        var foldedUTF8 = Array(foldedString.utf8)
                        let originalUTF8 = Array(source.utf8)

                        if foldedUTF8 == originalUTF8 {
                            switch unicodeScalar.properties.generalCategory {
                            case .nonspacingMark, .spacingMark, .enclosingMark, .format:
                                foldedUTF8 = []
                            default:
                                continue
                            }
                        }

                        entries.append(FoldEntry(from: decoded.scalar, foldedUTF8: foldedUTF8))
                    }
                }
            }
        }

        return buildLookup(entries)
    }

    public func stringNeedsFoldLookup(_ value: String) -> Bool {
        var copy = value
        return copy.withUTF8 { utf8 in
            guard let base = utf8.baseAddress else { return false }
            return Self.utf8NeedsFoldLookup(base, count: utf8.count, bits: Self.unicodeNeedsFoldBits)
        }
    }

    public func utf8ContainsNonIdentityFold(_ utf8: some Collection<UInt8>) -> Bool {
        let bytes = Array(utf8)
        return bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return false }
            return utf8ContainsNonIdentityFold(base, count: buf.count)
        }
    }

    @inline(__always)
    func lookupRaw(_ scalar: UInt32) -> UInt64? {
        rawTable.withUnsafeBufferPointer { tableBuf in
            guard let table = tableBuf.baseAddress else { return nil }
            return displacements.withUnsafeBufferPointer { displacementBuf in
                guard let displacementPtr = displacementBuf.baseAddress else { return nil }
                return lookupFoldRaw(
                    scalar,
                    table,
                    displacementPtr,
                    tableBuf.count,
                    displacementBuf.count,
                    seed1,
                    seed2
                )
            }
        }
    }

    func scalarExpansionMap() -> [UInt32: [UInt32]] {
        var map: [UInt32: [UInt32]] = [:]
        map.reserveCapacity(rawTable.count)
        for raw in rawTable {
            let entry = FoldEntry(raw: raw)
            let count = entry.count
            guard count > 0 else {
                map[entry.from] = []
                continue
            }

            var scalars: [UInt32] = []
            var pos = 0
            while pos < count {
                let b0 = entry.byte(pos)
                if b0 < 0x80 {
                    scalars.append(UInt32(b0))
                    pos &+= 1
                } else if b0 < 0xE0, pos &+ 1 < count {
                    scalars.append((UInt32(b0 & 0x1F) << 6) | UInt32(entry.byte(pos &+ 1) & 0x3F))
                    pos &+= 2
                } else if b0 < 0xF0, pos &+ 2 < count {
                    scalars.append((UInt32(b0 & 0x0F) << 12)
                        | (UInt32(entry.byte(pos &+ 1) & 0x3F) << 6)
                        | UInt32(entry.byte(pos &+ 2) & 0x3F))
                    pos &+= 3
                } else if pos &+ 3 < count {
                    scalars.append((UInt32(b0 & 0x07) << 18)
                        | (UInt32(entry.byte(pos &+ 1) & 0x3F) << 12)
                        | (UInt32(entry.byte(pos &+ 2) & 0x3F) << 6)
                        | UInt32(entry.byte(pos &+ 3) & 0x3F))
                    pos &+= 4
                } else {
                    break
                }
            }
            map[entry.from] = scalars
        }
        return map
    }

    @inline(__always)
    private func utf8ContainsNonIdentityFold(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        Self.utf8NeedsFoldLookup(bytes, count: count, bits: needsFoldBits)
    }

    @inline(__always)
    private static func utf8NeedsFoldLookup(_ bytes: UnsafePointer<UInt8>, count: Int, bits: [UInt64]) -> Bool {
        var pos = 0
        while pos < count {
            let b0 = bytes[pos]
            if b0 < 0x80 {
                pos &+= 1
                continue
            }

            guard let decoded = decodeUTF8Scalar(bytes, count, pos) else {
                pos &+= 1
                continue
            }
            let index = Int(decoded.scalar)
            let word = index >> 6
            let bit = UInt64(1) << UInt64(index & 63)
            if bits[word] & bit != 0 {
                return true
            }
            pos &+= decoded.sequenceLength
        }
        return false
    }

    private static func buildLookup(_ entries: [FoldEntry]) -> CasefoldingCache {
        guard !entries.isEmpty else {
            let emptyBits = [UInt64](repeating: 0, count: (0x110000 + 63) >> 6)
            return CasefoldingCache(rawTable: [], displacements: [], seed1: 0, seed2: 0, needsFoldBits: emptyBits)
        }

        var needsFoldBits = [UInt64](repeating: 0, count: (0x110000 + 63) >> 6)
        for entry in entries {
            let index = Int(entry.from)
            needsFoldBits[index >> 6] |= UInt64(1) << UInt64(index & 63)
        }

        let bucketFactors: [Double] = [0.25, 0.33, 0.5, 0.75, 1.0]
        var rng = FoldSeedGenerator(seed: UInt32(truncatingIfNeeded: entries.count &* 0x9E37_79B9))

        for _ in 0..<4096 {
            let seed1 = rng.next()
            let seed2 = rng.next()

            for factor in bucketFactors {
                if let cache = buildLookup(entries, bucketFactor: factor, seed1: seed1, seed2: seed2) {
                    return CasefoldingCache(
                        rawTable: cache.rawTable,
                        displacements: cache.displacements,
                        seed1: cache.seed1,
                        seed2: cache.seed2,
                        needsFoldBits: needsFoldBits
                    )
                }
            }
        }

        preconditionFailure("Unable to build casefold perfect hash")
    }

    private static func buildLookup(
        _ entries: [FoldEntry],
        bucketFactor: Double,
        seed1: UInt32,
        seed2: UInt32
    ) -> CasefoldingCache? {
        let tableSize = entries.count
        let bucketCount = max(1, Int((Double(tableSize) * bucketFactor).rounded(.up)))
        var buckets = Array(repeating: [Int](), count: bucketCount)
        for i in entries.indices {
            let bucket = foldHashBucket(entries[i].from, seed1, bucketCount)
            buckets[bucket].append(i)
        }

        let orderedBuckets = buckets.indices.sorted { buckets[$0].count > buckets[$1].count }
        var rawTable = [UInt64](repeating: 0, count: tableSize)
        var used = [Bool](repeating: false, count: tableSize)
        var displacements = [Int32](repeating: 0, count: bucketCount)
        var singletons: [Int] = []
        singletons.reserveCapacity(bucketCount)

        for bucket in orderedBuckets {
            let members = buckets[bucket]
            if members.isEmpty { continue }
            if members.count == 1 {
                singletons.append(members[0])
                continue
            }

            var displacement: UInt32 = 0
            var indices = [Int](repeating: 0, count: members.count)
            var found = false

            while !found {
                var collision = false
                for j in members.indices {
                    let key = entries[members[j]].from
                    let index = foldHashSlot(key, seed2, displacement, tableSize)
                    indices[j] = index
                    if used[index] {
                        collision = true
                        break
                    }
                    for k in 0..<j where indices[k] == index {
                        collision = true
                        break
                    }
                    if collision { break }
                }

                if !collision {
                    found = true
                    break
                }
                if displacement == .max {
                    return nil
                }
                displacement &+= 1
            }

            displacements[bucket] = Int32(displacement &+ 1)
            for j in members.indices {
                let index = indices[j]
                used[index] = true
                rawTable[index] = entries[members[j]].raw
            }
        }

        var freeIndex = 0
        for entryIndex in singletons {
            while freeIndex < tableSize, used[freeIndex] {
                freeIndex &+= 1
            }
            guard freeIndex < tableSize else { return nil }
            used[freeIndex] = true
            rawTable[freeIndex] = entries[entryIndex].raw
            let bucket = foldHashBucket(entries[entryIndex].from, seed1, bucketCount)
            displacements[bucket] = -(Int32(freeIndex) &+ 1)
        }

        for entry in entries {
            guard let raw = lookupFoldRaw(
                entry.from,
                rawTable,
                displacements,
                tableSize: tableSize,
                bucketCount: bucketCount,
                seed1: seed1,
                seed2: seed2
            ), raw == entry.raw else {
                return nil
            }
        }

        return CasefoldingCache(
            rawTable: rawTable,
            displacements: displacements,
            seed1: seed1,
            seed2: seed2,
            needsFoldBits: [UInt64]()
        )
    }

    private static func makeNeedsFoldBits(rawTable: [UInt64]) -> [UInt64] {
        var bits = [UInt64](repeating: 0, count: (0x110000 + 63) >> 6)
        for raw in rawTable {
            let scalar = Int(FoldEntry(raw: raw).from)
            bits[scalar >> 6] |= UInt64(1) << UInt64(scalar & 63)
        }
        return bits
    }

    private static func buildUnicodeNeedsFoldBits() -> [UInt64] {
        var bits = [UInt64](repeating: 0, count: (0x110000 + 63) >> 6)
        for scalar in UInt32(0x80)...UInt32(0x10FFFF) {
            guard let unicodeScalar = UnicodeScalar(scalar) else { continue }
            let source = String(unicodeScalar)
            let foldedString = source.folding(options: searchFoldOptions, locale: nil)
            var foldedUTF8 = Array(foldedString.utf8)
            let originalUTF8 = Array(source.utf8)

            if foldedUTF8 == originalUTF8 {
                switch unicodeScalar.properties.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark, .format:
                    foldedUTF8 = []
                default:
                    continue
                }
            }

            let index = Int(scalar)
            bits[index >> 6] |= UInt64(1) << UInt64(index & 63)
        }
        return bits
    }
}

@inline(__always)
private func lookupFoldRaw(
    _ scalar: UInt32,
    _ table: [UInt64],
    _ displacements: [Int32],
    tableSize: Int,
    bucketCount: Int,
    seed1: UInt32,
    seed2: UInt32
) -> UInt64? {
    table.withUnsafeBufferPointer { tableBuf in
        guard let tablePtr = tableBuf.baseAddress else { return nil }
        return displacements.withUnsafeBufferPointer { displacementBuf in
            guard let displacementPtr = displacementBuf.baseAddress else { return nil }
            return lookupFoldRaw(
                scalar,
                tablePtr,
                displacementPtr,
                tableSize,
                bucketCount,
                seed1,
                seed2
            )
        }
    }
}
