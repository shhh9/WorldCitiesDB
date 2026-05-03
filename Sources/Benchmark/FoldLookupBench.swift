import Darwin
import Foundation
import WorldCitiesDB

/// Micro-benchmark comparing fold table lookup strategies.
enum FoldLookupBench {
    // MARK: - Option 1: Binary search (same as lookupFold in library)

    @inline(__always)
    static func binaryLookup(
        _ scalar: UInt32,
        _ tbl: UnsafePointer<FoldEntry>,
        _ count: Int
    ) -> UnsafePointer<FoldEntry>? {
        guard count > 0 else { return nil }
        var lo = 0
        var hi = count &- 1
        while lo <= hi {
            let mid = (lo &+ hi) >> 1
            let mv = tbl[mid].from
            if mv == scalar { return tbl + mid }
            if mv < scalar { lo = mid &+ 1 }
            else { hi = mid &- 1 }
        }
        return nil
    }

    // MARK: - Option 2: Direct 21-bit lookup table (scalar → packed UInt64)

    static let directTableSize = 1 << 21  // 2,097,152

    static func buildDirectTable(_ entries: [FoldEntry]) -> [UInt64] {
        var table = [UInt64](repeating: UInt64.max, count: directTableSize)
        for entry in entries {
            let idx = Int(entry.from)
            guard idx < directTableSize else { continue }
            table[idx] = entry.raw
        }
        return table
    }

    @inline(__always)
    static func directLookup(
        _ scalar: UInt32,
        _ table: UnsafePointer<UInt64>
    ) -> UnsafePointer<UInt64>? {
        let idx = Int(scalar)
        guard idx < directTableSize else { return nil }
        let raw = table[idx]
        guard raw != UInt64.max else { return nil }
        return table + idx
    }

    // MARK: - Option 3: Linear scan

    @inline(__always)
    static func linearLookup(
        _ scalar: UInt32,
        _ tbl: UnsafePointer<FoldEntry>,
        _ count: Int
    ) -> UnsafePointer<FoldEntry>? {
        for i in 0..<count {
            if tbl[i].from == scalar { return tbl + i }
            if tbl[i].from > scalar { return nil }
        }
        return nil
    }

    // MARK: - Option 4: CHM minimal perfect hash

    private struct CHMEdge {
        let u: Int
        let v: Int
        let target: Int
    }

    struct CHMTable {
        let rawTable: [UInt64]     // rawTable[mph(scalar)] = FoldEntry.raw
        let g: [UInt32]            // CHM vertex values
        let vertexCount: Int
        let seed1: UInt32
        let seed2: UInt32
        let attempts: Int
        let loadFactor: Double

        var bytes: Int {
            rawTable.count * MemoryLayout<UInt64>.stride + g.count * MemoryLayout<UInt32>.stride
        }

        static func build(entries: [FoldEntry]) -> CHMTable? {
            let keys = entries.map(\.from)
            let n = keys.count
            guard n > 0 else {
                return CHMTable(
                    rawTable: [],
                    g: [],
                    vertexCount: 0,
                    seed1: 0,
                    seed2: 0,
                    attempts: 0,
                    loadFactor: 0
                )
            }

            let factors: [Double] = [1.60, 1.80, 2.00, 1.40, 1.30]
            let attemptsPerFactor = 8_000
            var globalAttempt = 0
            var rngState: UInt64 = 0xA076_1D64_78BD_642F

            func nextSeed() -> UInt32 {
                rngState &+= 0x9E37_79B9_7F4A_7C15
                var z = rngState
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                return UInt32(truncatingIfNeeded: z)
            }

            for factor in factors {
                let vertexCount = max(2, Int((Double(n) * factor).rounded(.up)))
                for _ in 0..<attemptsPerFactor {
                    globalAttempt &+= 1
                    let seed1 = nextSeed() | 1
                    var seed2 = nextSeed() | 1
                    if seed1 == seed2 { seed2 &+= 0x9E37_79B9 }

                    guard let g = buildCHMG(
                        keys: keys,
                        vertexCount: vertexCount,
                        seed1: seed1,
                        seed2: seed2
                    ) else {
                        continue
                    }

                    var rawTable = [UInt64](repeating: UInt64.max, count: n)
                    for entry in entries {
                        let idx = mphIndex(
                            entry.from,
                            g: g,
                            vertexCount: vertexCount,
                            seed1: seed1,
                            seed2: seed2,
                            tableSize: n
                        )
                        if rawTable[idx] != UInt64.max {
                            rawTable.removeAll(keepingCapacity: false)
                            break
                        }
                        rawTable[idx] = entry.raw
                    }

                    guard rawTable.count == n, !rawTable.contains(UInt64.max) else { continue }

                    return CHMTable(
                        rawTable: rawTable,
                        g: g,
                        vertexCount: vertexCount,
                        seed1: seed1,
                        seed2: seed2,
                        attempts: globalAttempt,
                        loadFactor: factor
                    )
                }
            }

            return nil
        }

        private static func buildCHMG(
            keys: [UInt32],
            vertexCount: Int,
            seed1: UInt32,
            seed2: UInt32
        ) -> [UInt32]? {
            let n = keys.count
            let modulo = UInt32(n)

            var edges: [CHMEdge] = []
            edges.reserveCapacity(n)
            var adjacency = Array(repeating: [Int](), count: vertexCount)
            var degree = [Int](repeating: 0, count: vertexCount)

            for (i, key) in keys.enumerated() {
                let u = chmVertex(key, seed: seed1, vertexCount: vertexCount)
                var v = chmVertex(key, seed: seed2, vertexCount: vertexCount)
                if v == u {
                    v = (v + 1 == vertexCount) ? 0 : (v + 1)
                }
                edges.append(CHMEdge(u: u, v: v, target: i))
                adjacency[u].append(i)
                adjacency[v].append(i)
                degree[u] &+= 1
                degree[v] &+= 1
            }

            var alive = [Bool](repeating: true, count: n)
            var queue: [Int] = []
            queue.reserveCapacity(vertexCount)
            for v in 0..<vertexCount where degree[v] == 1 {
                queue.append(v)
            }

            var peel: [(edge: Int, leaf: Int)] = []
            peel.reserveCapacity(n)
            var qi = 0
            while qi < queue.count {
                let leaf = queue[qi]
                qi &+= 1
                guard degree[leaf] == 1 else { continue }

                var edgeIdx = -1
                for e in adjacency[leaf] where alive[e] {
                    edgeIdx = e
                    break
                }
                guard edgeIdx >= 0 else { continue }

                alive[edgeIdx] = false
                peel.append((edge: edgeIdx, leaf: leaf))

                let edge = edges[edgeIdx]
                let other = (edge.u == leaf) ? edge.v : edge.u
                degree[leaf] &-= 1
                degree[other] &-= 1
                if degree[other] == 1 {
                    queue.append(other)
                }
            }

            guard peel.count == n else { return nil } // graph has a cycle

            var g = [UInt32](repeating: UInt32.max, count: vertexCount)
            for item in peel.reversed() {
                let edge = edges[item.edge]
                let leaf = item.leaf
                let other = (edge.u == leaf) ? edge.v : edge.u

                if g[other] == UInt32.max { g[other] = 0 }
                let otherValue = g[other] % modulo
                let target = UInt32(edge.target)
                g[leaf] = (target &+ modulo &- otherValue) % modulo
            }
            for i in 0..<g.count where g[i] == UInt32.max {
                g[i] = 0
            }

            var used = [Bool](repeating: false, count: n)
            for edge in edges {
                let idx = Int((g[edge.u] &+ g[edge.v]) % modulo)
                guard idx == edge.target, !used[idx] else { return nil }
                used[idx] = true
            }

            return g
        }
    }

    @inline(__always)
    static func mix32(_ x: UInt32) -> UInt32 {
        var z = x &+ 0x9E37_79B9
        z = (z ^ (z >> 16)) &* 0x85EB_CA6B
        z = (z ^ (z >> 13)) &* 0xC2B2_AE35
        return z ^ (z >> 16)
    }

    @inline(__always)
    static func chmVertex(_ key: UInt32, seed: UInt32, vertexCount: Int) -> Int {
        Int(mix32(key &+ seed) % UInt32(vertexCount))
    }

    @inline(__always)
    static func mphIndex(
        _ scalar: UInt32,
        g: [UInt32],
        vertexCount: Int,
        seed1: UInt32,
        seed2: UInt32,
        tableSize: Int
    ) -> Int {
        let u = chmVertex(scalar, seed: seed1, vertexCount: vertexCount)
        var v = chmVertex(scalar, seed: seed2, vertexCount: vertexCount)
        if v == u {
            v = (v + 1 == vertexCount) ? 0 : (v + 1)
        }
        return Int((g[u] &+ g[v]) % UInt32(tableSize))
    }

    @inline(__always)
    static func chmLookup(
        _ scalar: UInt32,
        _ table: UnsafePointer<UInt64>,
        _ g: UnsafePointer<UInt32>,
        _ tableSize: Int,
        _ vertexCount: Int,
        _ seed1: UInt32,
        _ seed2: UInt32
    ) -> UnsafePointer<UInt64>? {
        guard tableSize > 0 else { return nil }
        let u = chmVertex(scalar, seed: seed1, vertexCount: vertexCount)
        var v = chmVertex(scalar, seed: seed2, vertexCount: vertexCount)
        if v == u {
            v = (v + 1 == vertexCount) ? 0 : (v + 1)
        }
        let idx = Int((g[u] &+ g[v]) % UInt32(tableSize))
        let raw = table[idx]
        let storedFrom = UInt32((raw >> 32) & 0x0FFF_FFFF)
        guard storedFrom == scalar else { return nil }
        return table + idx
    }

    // MARK: - Option 5: CHD minimal perfect hash

    struct CHDTable {
        let rawTable: [UInt64]
        let g: [Int32]          // >0: displacement+1, <0: direct slot -(idx+1), 0: empty
        let bucketCount: Int
        let seed1: UInt32
        let seed2: UInt32
        let attempts: Int
        let elapsedNs: UInt64
        let maxDisplacement: UInt32

        var bytes: Int {
            rawTable.count * MemoryLayout<UInt64>.stride + g.count * MemoryLayout<Int32>.stride
        }
    }

    @inline(__always)
    static func chdBucket(_ key: UInt32, _ seed: UInt32, _ bucketCount: Int) -> Int {
        Int(mix32(key &+ seed) % UInt32(bucketCount))
    }

    @inline(__always)
    static func chdSlot(_ key: UInt32, _ seed: UInt32, _ displacement: UInt32, _ tableSize: Int) -> Int {
        let mixed = mix32(key &+ seed &+ (displacement &* 0x9E37_79B9))
        return Int(mixed % UInt32(tableSize))
    }

    static func buildCHDTable(
        entries: [FoldEntry],
        maxAttempts: Int = 4_000
    ) -> CHDTable? {
        let n = entries.count
        guard n > 0 else {
            return CHDTable(
                rawTable: [],
                g: [],
                bucketCount: 0,
                seed1: 0,
                seed2: 0,
                attempts: 0,
                elapsedNs: 0,
                maxDisplacement: 0
            )
        }

        let buildStart = DispatchTime.now().uptimeNanoseconds
        let bucketFactors: [Double] = [0.25, 0.33, 0.5, 0.75, 1.0]
        var rng = SplitMix64(seed: 0xD134_2543_DE82_EF95 ^ UInt64(n))

        for attempt in 1...maxAttempts {
            let seed1 = rng.nextUInt32() | 1
            let seed2 = rng.nextUInt32() | 1

            for factor in bucketFactors {
                let bucketCount = max(1, Int((Double(n) * factor).rounded(.up)))
                var buckets = Array(repeating: [Int](), count: bucketCount)
                buckets.withUnsafeMutableBufferPointer { _ in }
                for i in 0..<n {
                    let b = chdBucket(entries[i].from, seed1, bucketCount)
                    buckets[b].append(i)
                }

                let orderedBuckets = (0..<bucketCount).sorted { lhs, rhs in
                    buckets[lhs].count > buckets[rhs].count
                }

                var rawTable = [UInt64](repeating: UInt64.max, count: n)
                var used = [Bool](repeating: false, count: n)
                var g = [Int32](repeating: 0, count: bucketCount)
                var singletons: [Int] = []
                singletons.reserveCapacity(bucketCount)
                var maxDisplacement: UInt32 = 0
                var success = true

                for b in orderedBuckets {
                    let members = buckets[b]
                    if members.isEmpty { continue }
                    if members.count == 1 {
                        singletons.append(members[0])
                        continue
                    }

                    var displacement: UInt32 = 0
                    var found = false
                    var idxBuf = [Int](repeating: 0, count: members.count)
                    while true {
                        var collision = false
                        for j in 0..<members.count {
                            let key = entries[members[j]].from
                            let idx = chdSlot(key, seed2, displacement, n)
                            idxBuf[j] = idx
                            if used[idx] {
                                collision = true
                                break
                            }
                            for k in 0..<j where idxBuf[k] == idx {
                                collision = true
                                break
                            }
                            if collision { break }
                        }

                        if !collision {
                            found = true
                            break
                        }

                        if displacement == UInt32.max {
                            break
                        }
                        displacement &+= 1
                    }

                    if !found {
                        success = false
                        break
                    }

                    g[b] = Int32(displacement &+ 1)
                    if displacement > maxDisplacement { maxDisplacement = displacement }
                    for j in 0..<members.count {
                        let idx = idxBuf[j]
                        used[idx] = true
                        rawTable[idx] = entries[members[j]].raw
                    }
                }

                if !success { continue }

                var freeIdx = 0
                for entryIndex in singletons {
                    while freeIdx < n, used[freeIdx] { freeIdx &+= 1 }
                    guard freeIdx < n else {
                        success = false
                        break
                    }
                    used[freeIdx] = true
                    rawTable[freeIdx] = entries[entryIndex].raw
                    let b = chdBucket(entries[entryIndex].from, seed1, bucketCount)
                    g[b] = -(Int32(freeIdx) &+ 1)
                }

                if !success { continue }

                // Verify perfect mapping for all build keys.
                for entry in entries {
                    let b = chdBucket(entry.from, seed1, bucketCount)
                    let gv = g[b]
                    if gv == 0 {
                        success = false
                        break
                    }
                    let idx: Int
                    if gv < 0 {
                        idx = Int(-gv - 1)
                    } else {
                        idx = chdSlot(entry.from, seed2, UInt32(gv - 1), n)
                    }
                    if rawTable[idx] != entry.raw {
                        success = false
                        break
                    }
                }

                if !success { continue }

                let elapsedNs = DispatchTime.now().uptimeNanoseconds - buildStart
                return CHDTable(
                    rawTable: rawTable,
                    g: g,
                    bucketCount: bucketCount,
                    seed1: seed1,
                    seed2: seed2,
                    attempts: attempt,
                    elapsedNs: elapsedNs,
                    maxDisplacement: maxDisplacement
                )
            }
        }

        return nil
    }

    @inline(__always)
    static func chdLookup(
        _ scalar: UInt32,
        _ table: UnsafePointer<UInt64>,
        _ g: UnsafePointer<Int32>,
        _ tableSize: Int,
        _ bucketCount: Int,
        _ seed1: UInt32,
        _ seed2: UInt32
    ) -> UnsafePointer<UInt64>? {
        guard tableSize > 0, bucketCount > 0 else { return nil }
        let b = chdBucket(scalar, seed1, bucketCount)
        let gv = g[b]
        guard gv != 0 else { return nil }

        let idx: Int
        if gv < 0 {
            idx = Int(-gv - 1)
        } else {
            idx = chdSlot(scalar, seed2, UInt32(gv - 1), tableSize)
        }

        let raw = table[idx]
        guard raw != UInt64.max else { return nil }
        let storedFrom = UInt32((raw >> 32) & 0x0FFF_FFFF)
        guard storedFrom == scalar else { return nil }
        return table + idx
    }

    // MARK: - Option 6: Multiplicative mod-N perfect hash

    struct MulModTable {
        let rawTable: [UInt64] // rawTable[(scalar * seed) % N] = FoldEntry.raw (or UInt64.max)
        let tableSize: Int     // N
        let seed: UInt32
        let mask: UInt32?       // N-1 when N is power-of-two
        let attempts: Int
        let buildNs: UInt64
        let usedMaskPath: Bool

        var bytes: Int { rawTable.count * MemoryLayout<UInt64>.stride }
    }

    @inline(__always)
    static func gcd(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var x = a
        var y = b
        while y != 0 {
            let r = x % y
            x = y
            y = r
        }
        return x
    }

    @inline(__always)
    static func isPowerOfTwo(_ x: Int) -> Bool {
        x > 0 && (x & (x - 1)) == 0
    }

    @inline(__always)
    static func mulModIndex(_ scalar: UInt32, seed: UInt32, tableSize: Int) -> Int {
        if isPowerOfTwo(tableSize) {
            return Int((scalar &* seed) & UInt32(tableSize &- 1))
        }
        return Int((UInt64(scalar) &* UInt64(seed)) % UInt64(tableSize))
    }

    static func searchMulModTables(
        entries: [FoldEntry],
        candidateNs: [Int],
        maxAttemptsPerN: Int
    ) -> [MulModTable] {
        let keys = entries.map(\.from)
        guard !keys.isEmpty else { return [] }

        var results: [MulModTable] = []
        results.reserveCapacity(candidateNs.count)

        var rngState: UInt64 = 0x1234_5678_9ABC_DEF0
        func nextSeed() -> UInt32 {
            rngState &+= 0x9E37_79B9_7F4A_7C15
            var z = rngState
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return UInt32(truncatingIfNeeded: z)
        }

        for tableSize in candidateNs {
            guard tableSize >= keys.count else { continue }

            let buildStart = DispatchTime.now().uptimeNanoseconds
            var seen = [UInt32](repeating: 0, count: tableSize)
            var stamp: UInt32 = 1
            var found: (seed: UInt32, attempts: Int)?

            for attempt in 1...maxAttemptsPerN {
                var seed = nextSeed() | 1
                if !isPowerOfTwo(tableSize) {
                    // Ensure multiplication is invertible modulo N.
                    while gcd(seed, UInt32(tableSize)) != 1 {
                        seed = nextSeed() | 1
                    }
                }

                let token = stamp
                stamp &+= 1
                if stamp == 0 {
                    seen = [UInt32](repeating: 0, count: tableSize)
                    stamp = 1
                }

                var collision = false
                for key in keys {
                    let idx = mulModIndex(key, seed: seed, tableSize: tableSize)
                    if seen[idx] == token {
                        collision = true
                        break
                    }
                    seen[idx] = token
                }

                if !collision {
                    found = (seed, attempt)
                    break
                }
            }

            guard let found else { continue }

            var rawTable = [UInt64](repeating: UInt64.max, count: tableSize)
            var valid = true
            for entry in entries {
                let idx = mulModIndex(entry.from, seed: found.seed, tableSize: tableSize)
                if rawTable[idx] != UInt64.max {
                    valid = false
                    break
                }
                rawTable[idx] = entry.raw
            }
            guard valid else { continue }

            let buildNs = DispatchTime.now().uptimeNanoseconds - buildStart
            results.append(MulModTable(
                rawTable: rawTable,
                tableSize: tableSize,
                seed: found.seed,
                mask: isPowerOfTwo(tableSize) ? UInt32(tableSize - 1) : nil,
                attempts: found.attempts,
                buildNs: buildNs,
                usedMaskPath: isPowerOfTwo(tableSize)
            ))
        }

        return results
    }

    static func buildMulModTable(
        entries: [FoldEntry],
        tableSize: Int,
        seed: UInt32
    ) -> MulModTable? {
        guard tableSize >= entries.count, tableSize > 0 else { return nil }
        let buildStart = DispatchTime.now().uptimeNanoseconds

        var rawTable = [UInt64](repeating: UInt64.max, count: tableSize)
        for entry in entries {
            let idx = mulModIndex(entry.from, seed: seed, tableSize: tableSize)
            if rawTable[idx] != UInt64.max { return nil }
            rawTable[idx] = entry.raw
        }

        let buildNs = DispatchTime.now().uptimeNanoseconds - buildStart
        return MulModTable(
            rawTable: rawTable,
            tableSize: tableSize,
            seed: seed,
            mask: isPowerOfTwo(tableSize) ? UInt32(tableSize - 1) : nil,
            attempts: 1,
            buildNs: buildNs,
            usedMaskPath: isPowerOfTwo(tableSize)
        )
    }

    static func firstWorkingMulModN(
        keys: [UInt32],
        minN: Int,
        maxN: Int
    ) -> Int? {
        guard !keys.isEmpty, minN <= maxN else { return nil }
        var seen = [UInt32](repeating: 0, count: maxN)
        var stamp: UInt32 = 1

        for tableSize in minN...maxN {
            let token = stamp
            stamp &+= 1
            if stamp == 0 {
                seen = [UInt32](repeating: 0, count: maxN)
                stamp = 1
            }

            var collision = false
            let mod = UInt32(tableSize)
            for key in keys {
                let idx = Int(key % mod)
                if seen[idx] == token {
                    collision = true
                    break
                }
                seen[idx] = token
            }
            if !collision {
                return tableSize
            }
        }
        return nil
    }

    @inline(__always)
    static func mulModLookup(
        _ scalar: UInt32,
        _ table: UnsafePointer<UInt64>,
        _ tableSize: Int,
        _ seed: UInt32
    ) -> UnsafePointer<UInt64>? {
        guard tableSize > 0 else { return nil }
        let idx = mulModIndex(scalar, seed: seed, tableSize: tableSize)
        let raw = table[idx]
        guard raw != UInt64.max else { return nil }
        let storedFrom = UInt32((raw >> 32) & 0x0FFF_FFFF)
        guard storedFrom == scalar else { return nil }
        return table + idx
    }

    @inline(__always)
    static func mulMaskLookup(
        _ scalar: UInt32,
        _ table: UnsafePointer<UInt64>,
        _ mask: UInt32,
        _ seed: UInt32
    ) -> UnsafePointer<UInt64>? {
        let idx = Int((scalar &* seed) & mask)
        let raw = table[idx]
        guard raw != UInt64.max else { return nil }
        let storedFrom = UInt32((raw >> 32) & 0x0FFF_FFFF)
        guard storedFrom == scalar else { return nil }
        return table + idx
    }

    // MARK: - Option 6: Multiplicative shift-and-mask perfect hash

    struct MulShiftMaskTable {
        let rawTable: [UInt64] // rawTable[mix64(scalar,seed) & mask] = FoldEntry.raw
        let bits: Int
        let seed: UInt32
        let attempts: Int
        let elapsedNs: UInt64

        var tableSize: Int { 1 << bits }
        var mask: UInt32 { UInt32(tableSize - 1) }
        var bytes: Int { rawTable.count * MemoryLayout<UInt64>.stride }
    }

    struct MulShiftSearchStep {
        let bits: Int
        let attempts: Int
        let elapsedNs: UInt64
        let found: Bool
        let seed: UInt32?
    }

    struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func nextUInt64() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return z
        }

        mutating func nextUInt32() -> UInt32 {
            UInt32(truncatingIfNeeded: nextUInt64())
        }
    }

    @inline(__always)
    static func minimumBitsToHold(_ count: Int) -> Int {
        var bits = 0
        var capacity = 1
        while capacity < count {
            capacity <<= 1
            bits &+= 1
        }
        return bits
    }

    @inline(__always)
    static func hashToUInt64(_ i: UInt64) -> UInt64 {
        // Fibonacci hashing to 10-bit value.
        (i &* 11_400_714_819_323_198_485) >> 54
    }

    @inline(__always)
    static func mulShiftMaskIndex(_ scalar: UInt32, _ seed: UInt32, _ mask: UInt32) -> Int {
        let mixed = hashToUInt64(UInt64(scalar) &+ UInt64(seed))
        return Int(mixed & UInt64(mask))
    }

    static func searchMulShiftMaskTable(
        entries: [FoldEntry],
        secondsPerBits: Double = 10.0,
        checkEvery: Int = 1_000_000,
        maxBits: Int = 24
    ) -> (table: MulShiftMaskTable?, steps: [MulShiftSearchStep]) {
        guard !entries.isEmpty else { return (nil, []) }

        let keys = entries.map(\.from)
        let minBits = minimumBitsToHold(keys.count)
        let effectiveMaxBits = min(maxBits, 10) // hashToUInt64 emits 10 bits
        guard minBits <= effectiveMaxBits else { return (nil, []) }

        let budgetNs = UInt64(secondsPerBits * 1_000_000_000)
        var steps: [MulShiftSearchStep] = []
        steps.reserveCapacity(effectiveMaxBits - minBits + 1)

        var rng = SplitMix64(seed: DispatchTime.now().uptimeNanoseconds ^ 0xA076_1D64_78BD_642F)

        for bits in minBits...effectiveMaxBits {
            let tableSize = 1 << bits
            let mask = UInt32(tableSize - 1)

            var seen = [UInt32](repeating: 0, count: tableSize)
            var stamp: UInt32 = 1
            var attempts = 0
            let startNs = DispatchTime.now().uptimeNanoseconds

            while true {
                attempts &+= 1
                let seed = rng.nextUInt32()

                let token = stamp
                stamp &+= 1
                if stamp == 0 {
                    seen = [UInt32](repeating: 0, count: tableSize)
                    stamp = 1
                }

                var collision = false
                for key in keys {
                    let idx = mulShiftMaskIndex(key, seed, mask)
                    if seen[idx] == token {
                        collision = true
                        break
                    }
                    seen[idx] = token
                }

                if !collision {
                    var rawTable = [UInt64](repeating: UInt64.max, count: tableSize)
                    for entry in entries {
                        let idx = mulShiftMaskIndex(entry.from, seed, mask)
                        rawTable[idx] = entry.raw
                    }
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds - startNs
                    steps.append(MulShiftSearchStep(
                        bits: bits,
                        attempts: attempts,
                        elapsedNs: elapsedNs,
                        found: true,
                        seed: seed
                    ))
                    return (
                        MulShiftMaskTable(
                            rawTable: rawTable,
                            bits: bits,
                            seed: seed,
                            attempts: attempts,
                            elapsedNs: elapsedNs
                        ),
                        steps
                    )
                }

                if attempts % checkEvery == 0 {
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds - startNs
                    if elapsedNs >= budgetNs {
                        steps.append(MulShiftSearchStep(
                            bits: bits,
                            attempts: attempts,
                            elapsedNs: elapsedNs,
                            found: false,
                            seed: nil
                        ))
                        break
                    }
                }
            }
        }

        return (nil, steps)
    }

    @inline(__always)
    static func mulShiftMaskLookup(
        _ scalar: UInt32,
        _ table: UnsafePointer<UInt64>,
        _ mask: UInt32,
        _ seed: UInt32
    ) -> UnsafePointer<UInt64>? {
        let idx = mulShiftMaskIndex(scalar, seed, mask)
        let raw = table[idx]
        guard raw != UInt64.max else { return nil }
        let storedFrom = UInt32((raw >> 32) & 0x0FFF_FFFF)
        guard storedFrom == scalar else { return nil }
        return table + idx
    }

    // MARK: - Benchmark

    static func run() {
        let cityURL = URL(fileURLWithPath: "Sources/WorldCitiesDB/Resources/cities.wcdb")
        let db = try! WorldCitiesDB<City>(data: Data(contentsOf: cityURL))
        let cities = db.cities
        let cache = db.casefoldingCache
        let entries = cache.entries

        print("FoldLookupBench: \(entries.count) fold entries")
        print("  FoldEntry size: \(MemoryLayout<FoldEntry>.stride) bytes")
        print("  Fold table:     \(entries.count * MemoryLayout<FoldEntry>.stride) bytes")
        print("  Direct table:   \(directTableSize * 8 / 1024 / 1024) MB")

        // Collect all non-ASCII scalars from city data for realistic lookup patterns
        var testScalars: [UInt32] = []
        testScalars.reserveCapacity(500_000)
        for city in cities {
            let fields = [city.name, city.asciiName] + city.alternateNames + city.alternateAsciiNames
            for field in fields {
                for scalar in field.unicodeScalars {
                    if scalar.value >= 0x80 {
                        testScalars.append(scalar.value)
                    }
                }
            }
        }
        print("  Test scalars:   \(testScalars.count)")
        let benchmarkScalars = testScalars
        print("  Bench scalars:  \(benchmarkScalars.count)")

        // Build direct table
        let directTable = buildDirectTable(entries)

        // Build CHM minimal perfect hash table
        print()
        let chmBuildStart = DispatchTime.now().uptimeNanoseconds
        guard let chmTable = CHMTable.build(entries: entries) else {
            print("  Failed to build CHM minimal perfect hash table")
            return
        }
        let chmBuildNs = DispatchTime.now().uptimeNanoseconds - chmBuildStart
        print("  CHM table:       \(chmTable.bytes / 1024) KB (entries + g)")
        print("  CHM params:      vertices=\(chmTable.vertexCount), seed1=0x\(String(chmTable.seed1, radix: 16)), seed2=0x\(String(chmTable.seed2, radix: 16))")
        print("  CHM build:       \(String(format: "%.3f", Double(chmBuildNs) / 1e6)) ms (attempts=\(chmTable.attempts), loadFactor=\(String(format: "%.2f", chmTable.loadFactor)))")

        let chdBuildStart = DispatchTime.now().uptimeNanoseconds
        guard let chdTable = buildCHDTable(entries: entries) else {
            print("  Failed to build CHD minimal perfect hash table")
            return
        }
        let chdBuildNs = DispatchTime.now().uptimeNanoseconds - chdBuildStart
        print("  CHD table:       \(chdTable.bytes / 1024) KB (entries + g)")
        print("  CHD params:      buckets=\(chdTable.bucketCount), seed1=0x\(String(chdTable.seed1, radix: 16)), seed2=0x\(String(chdTable.seed2, radix: 16))")
        print("  CHD build:       \(String(format: "%.3f", Double(chdBuildNs) / 1e6)) ms (attempts=\(chdTable.attempts), maxDisp=\(chdTable.maxDisplacement))")

        // Search mixed UInt64 perfect hash:
        // i = UInt64(x) + UInt64(seed); i += 1; i ^= i >> 33; i *= 0xff51afd7ed558ccd
        // idx = i & ((1 << bits) - 1)
        let shiftSearch = searchMulShiftMaskTable(
            entries: entries,
            secondsPerBits: 10.0,
            checkEvery: 1_000_000,
            maxBits: 24
        )
        print("  Mix64 hash:      y=((x+seed)*11400714819323198485)>>54 (10 bits); idx=y&((1<<bits)-1)")
        print("  Mix64 search:    10.0s per bits, random UInt32 seed, check elapsed every 1,000,000 attempts")
        for step in shiftSearch.steps {
            if step.found {
                print("    bits=\(step.bits), N=\(1 << step.bits), attempts=\(step.attempts), elapsed=\(String(format: "%.3f", Double(step.elapsedNs) / 1e9))s, seed=0x\(String(step.seed!, radix: 16))")
            } else {
                print("    bits=\(step.bits), N=\(1 << step.bits), attempts=\(step.attempts), elapsed=\(String(format: "%.3f", Double(step.elapsedNs) / 1e9))s, no perfect hash")
            }
        }
        let mulShiftTable = shiftSearch.table
        if let mulShiftTable {
            print("  Mix64 table:     \(mulShiftTable.bytes / 1024) KB")
            print("  Mix64 params:    bits=\(mulShiftTable.bits), N=\(mulShiftTable.tableSize), seed=0x\(String(mulShiftTable.seed, radix: 16))")
            print("  Mix64 build:     \(String(format: "%.3f", Double(mulShiftTable.elapsedNs) / 1e6)) ms (attempts=\(mulShiftTable.attempts))")
        } else {
            print("  Mix64 result:    no perfect hash found up to bits=24")
        }

        // Analyze scalar range for compact direct table
        let minScalar = entries.map(\.from).min() ?? 0
        let maxScalar = entries.map(\.from).max() ?? 0
        let range = Int(maxScalar) - Int(minScalar) + 1
        print()
        print("  Scalar range:    0x\(String(minScalar, radix: 16))–0x\(String(maxScalar, radix: 16)) (range=\(range), \(range * 8 / 1024) KB)")

        // Build compact direct table (offset by minScalar)
        let compactSize = range
        var compactTable = [UInt64](repeating: UInt64.max, count: compactSize)
        for entry in entries {
            compactTable[Int(entry.from) - Int(minScalar)] = entry.raw
        }
        let compactBase = minScalar
        print("  Compact table:   \(compactSize) entries, \(compactSize * 8 / 1024) KB")

        // Search for mulMask perfect hash (power-of-two table sizes)
        let candidateNs = [1024, 2048, 4096, 8192]
        let mulModResults = searchMulModTables(
            entries: entries,
            candidateNs: candidateNs,
            maxAttemptsPerN: 10_000_000
        )
        print()
        print("  MulMask search:  idx = (scalar * seed) & mask")
        for r in mulModResults {
            let load = String(format: "%.1f%%", Double(entries.count) * 100.0 / Double(r.tableSize))
            print("    N=\(r.tableSize), seed=0x\(String(r.seed, radix: 16)), "
                + "attempts=\(r.attempts), "
                + "build=\(String(format: "%.3f", Double(r.buildNs) / 1e6)) ms, "
                + "mem=\(r.bytes / 1024) KB, load=\(load)"
                + (r.usedMaskPath ? " [mask]" : " [mod]"))
        }
        let bestMulMask = mulModResults.first { $0.usedMaskPath }

        // Verify CHM + CHD correctness against binary search
        var chmMismatches = 0
        var chdMismatches = 0
        entries.withUnsafeBufferPointer { tblBuf in
            let tp = tblBuf.baseAddress!
            let tc = tblBuf.count
            chmTable.rawTable.withUnsafeBufferPointer { chmBuf in
                let chmPtr = chmBuf.baseAddress!
                chmTable.g.withUnsafeBufferPointer { chmGBuf in
                    let chmGPtr = chmGBuf.baseAddress!
                    chdTable.rawTable.withUnsafeBufferPointer { chdBuf in
                        let chdPtr = chdBuf.baseAddress!
                        chdTable.g.withUnsafeBufferPointer { chdGBuf in
                            let chdGPtr = chdGBuf.baseAddress!
                            for s in testScalars {
                                let bResult = binaryLookup(s, tp, tc)
                                let chmResult = chmLookup(
                                    s,
                                    chmPtr,
                                    chmGPtr,
                                    chmTable.rawTable.count,
                                    chmTable.vertexCount,
                                    chmTable.seed1,
                                    chmTable.seed2
                                )
                                let chdResult = chdLookup(
                                    s,
                                    chdPtr,
                                    chdGPtr,
                                    chdTable.rawTable.count,
                                    chdTable.bucketCount,
                                    chdTable.seed1,
                                    chdTable.seed2
                                )
                                let bCount = bResult.map { Int($0.pointee.count) }
                                let chmCount = chmResult.map { Int(FoldEntry(raw: $0.pointee).count) }
                                let chdCount = chdResult.map { Int(FoldEntry(raw: $0.pointee).count) }
                                if bCount != chmCount { chmMismatches &+= 1 }
                                if bCount != chdCount { chdMismatches &+= 1 }
                            }
                        }
                    }
                }
            }
        }
        let chmStatus = chmMismatches == 0 ? "PASS" : "FAIL (\(chmMismatches) mismatches)"
        let chdStatus = chdMismatches == 0 ? "PASS" : "FAIL (\(chdMismatches) mismatches)"
        print("  Verification: CHM=\(chmStatus), CHD=\(chdStatus)")

        let iterations = 3

        // Warmup + benchmark: Binary search (current)
        var binaryChecksum: UInt64 = 0
        var binaryNs: UInt64 = 0
        entries.withUnsafeBufferPointer { tblBuf in
            let tp = tblBuf.baseAddress!
            let tc = tblBuf.count
            for s in benchmarkScalars { _ = binaryLookup(s, tp, tc) }
            for _ in 0..<iterations {
                let t0 = DispatchTime.now().uptimeNanoseconds
                for s in benchmarkScalars {
                    let bResult = binaryLookup(s, tp, tc)
                    if let bResult {
                        binaryChecksum &+= UInt64(bResult.pointee.count)
                    }
                }
                binaryNs &+= DispatchTime.now().uptimeNanoseconds - t0
            }
        }

        // Warmup + benchmark: Direct table
        var directChecksum: UInt64 = 0
        var directNs: UInt64 = 0
        directTable.withUnsafeBufferPointer { buf in
            let tp = buf.baseAddress!
            for s in benchmarkScalars { _ = directLookup(s, tp) }
            for _ in 0..<iterations {
                let t0 = DispatchTime.now().uptimeNanoseconds
                for s in benchmarkScalars {
                    if let e = directLookup(s, tp) {
                        directChecksum &+= UInt64(FoldEntry(raw: e.pointee).count)
                    }
                }
                directNs &+= DispatchTime.now().uptimeNanoseconds - t0
            }
        }

        // Warmup + benchmark: Linear scan
        var linearChecksum: UInt64 = 0
        var linearNs: UInt64 = 0
        entries.withUnsafeBufferPointer { tblBuf in
            let tp = tblBuf.baseAddress!
            let tc = tblBuf.count
            for s in benchmarkScalars { _ = linearLookup(s, tp, tc) }
            for _ in 0..<iterations {
                let t0 = DispatchTime.now().uptimeNanoseconds
                for s in benchmarkScalars {
                    if let e = linearLookup(s, tp, tc) {
                        linearChecksum &+= UInt64(e.pointee.count)
                    }
                }
                linearNs &+= DispatchTime.now().uptimeNanoseconds - t0
            }
        }

        // Warmup + benchmark: CHM minimal perfect hash
        var chmChecksum: UInt64 = 0
        var chmNs: UInt64 = 0
        chmTable.rawTable.withUnsafeBufferPointer { tableBuf in
            let tablePtr = tableBuf.baseAddress!
            chmTable.g.withUnsafeBufferPointer { gBuf in
                let gPtr = gBuf.baseAddress!
                for s in benchmarkScalars {
                    _ = chmLookup(
                        s,
                        tablePtr,
                        gPtr,
                        chmTable.rawTable.count,
                        chmTable.vertexCount,
                        chmTable.seed1,
                        chmTable.seed2
                    )
                }
            for _ in 0..<iterations {
                let t0 = DispatchTime.now().uptimeNanoseconds
                for s in benchmarkScalars {
                    if let e = chmLookup(
                        s,
                        tablePtr,
                        gPtr,
                        chmTable.rawTable.count,
                        chmTable.vertexCount,
                        chmTable.seed1,
                        chmTable.seed2
                    ) {
                        chmChecksum &+= UInt64(FoldEntry(raw: e.pointee).count)
                    }
                }
                chmNs &+= DispatchTime.now().uptimeNanoseconds - t0
            }
            }
        }

        // Warmup + benchmark: CHD minimal perfect hash
        var chdChecksum: UInt64 = 0
        var chdNs: UInt64 = 0
        chdTable.rawTable.withUnsafeBufferPointer { tableBuf in
            let tablePtr = tableBuf.baseAddress!
            chdTable.g.withUnsafeBufferPointer { gBuf in
                let gPtr = gBuf.baseAddress!
                for s in benchmarkScalars {
                    _ = chdLookup(
                        s,
                        tablePtr,
                        gPtr,
                        chdTable.rawTable.count,
                        chdTable.bucketCount,
                        chdTable.seed1,
                        chdTable.seed2
                    )
                }
                for _ in 0..<iterations {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    for s in benchmarkScalars {
                        if let e = chdLookup(
                            s,
                            tablePtr,
                            gPtr,
                            chdTable.rawTable.count,
                            chdTable.bucketCount,
                            chdTable.seed1,
                            chdTable.seed2
                        ) {
                            chdChecksum &+= UInt64(FoldEntry(raw: e.pointee).count)
                        }
                    }
                    chdNs &+= DispatchTime.now().uptimeNanoseconds - t0
                }
            }
        }

        // Warmup + benchmark: Multiplicative shift-and-mask perfect hash
        var mulShiftChecksum: UInt64 = 0
        var mulShiftNs: UInt64 = 0
        if let mulShiftTable {
            mulShiftTable.rawTable.withUnsafeBufferPointer { buf in
                let tp = buf.baseAddress!
                let mask = mulShiftTable.mask
                let seed = mulShiftTable.seed
                for s in benchmarkScalars { _ = mulShiftMaskLookup(s, tp, mask, seed) }
                for _ in 0..<iterations {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    for s in benchmarkScalars {
                        if let e = mulShiftMaskLookup(s, tp, mask, seed) {
                            mulShiftChecksum &+= UInt64(FoldEntry(raw: e.pointee).count)
                        }
                    }
                    mulShiftNs &+= DispatchTime.now().uptimeNanoseconds - t0
                }
            }
        }
        // Warmup + benchmark: Compact direct table
        var compactChecksum: UInt64 = 0
        var compactNs: UInt64 = 0
        compactTable.withUnsafeBufferPointer { buf in
            let tp = buf.baseAddress!
            let base = compactBase
            let sz = UInt32(compactSize)
            for s in benchmarkScalars {
                let off = s &- base
                if off < sz {
                    let raw = tp[Int(off)]
                    if raw != UInt64.max { compactChecksum &+= 1 } // warmup
                }
            }
            compactChecksum = 0
            for _ in 0..<iterations {
                let t0 = DispatchTime.now().uptimeNanoseconds
                for s in benchmarkScalars {
                    let off = s &- base
                    if off < sz {
                        let raw = tp[Int(off)]
                        if raw != UInt64.max {
                            compactChecksum &+= UInt64(FoldEntry(raw: raw).count)
                        }
                    }
                }
                compactNs &+= DispatchTime.now().uptimeNanoseconds - t0
            }
        }

        // Warmup + benchmark: MulMask perfect hash
        var mulMaskChecksum: UInt64 = 0
        var mulMaskNs: UInt64 = 0
        if let bestMulMask {
            bestMulMask.rawTable.withUnsafeBufferPointer { buf in
                let tp = buf.baseAddress!
                let mask = bestMulMask.mask!
                let seed = bestMulMask.seed
                for s in benchmarkScalars { _ = mulMaskLookup(s, tp, mask, seed) }
                for _ in 0..<iterations {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    for s in benchmarkScalars {
                        if let e = mulMaskLookup(s, tp, mask, seed) {
                            mulMaskChecksum &+= UInt64(FoldEntry(raw: e.pointee).count)
                        }
                    }
                    mulMaskNs &+= DispatchTime.now().uptimeNanoseconds - t0
                }
            }
        }

        let totalLookups = benchmarkScalars.count * iterations

        print()
        var strategyCount = 5
        if mulShiftTable != nil { strategyCount += 1 }
        if bestMulMask != nil { strategyCount += 1 }
        print("  \(totalLookups) lookups × \(strategyCount) strategies:")
        print()
        print("  1) Binary search:  \(String(format: "%8.2f", Double(binaryNs) / 1e6)) ms  " +
              "(\(String(format: "%.1f", Double(binaryNs) / Double(totalLookups))) ns/lookup)  checksum=\(binaryChecksum)")
        print("  2) Direct table:   \(String(format: "%8.2f", Double(directNs) / 1e6)) ms  " +
              "(\(String(format: "%.1f", Double(directNs) / Double(totalLookups))) ns/lookup)  checksum=\(directChecksum)")
        print("  3) Linear scan:    \(String(format: "%8.2f", Double(linearNs) / 1e6)) ms  " +
              "(\(String(format: "%.1f", Double(linearNs) / Double(totalLookups))) ns/lookup)  checksum=\(linearChecksum)")
        print("  4) CHM MPH:        \(String(format: "%8.2f", Double(chmNs) / 1e6)) ms  " +
              "(\(String(format: "%.1f", Double(chmNs) / Double(totalLookups))) ns/lookup)  checksum=\(chmChecksum)")
        print("  5) CHD MPH:        \(String(format: "%8.2f", Double(chdNs) / 1e6)) ms  " +
              "(\(String(format: "%.1f", Double(chdNs) / Double(totalLookups))) ns/lookup)  checksum=\(chdChecksum)")
        if let mulShiftTable {
            print("  6) Mix64 PH:       \(String(format: "%8.2f", Double(mulShiftNs) / 1e6)) ms  " +
                  "(\(String(format: "%.1f", Double(mulShiftNs) / Double(totalLookups))) ns/lookup)  checksum=\(mulShiftChecksum)  [bits=\(mulShiftTable.bits), N=\(mulShiftTable.tableSize), seed=0x\(String(mulShiftTable.seed, radix: 16)), mem=\(mulShiftTable.bytes / 1024) KB]")
        }

        print("  7) Compact direct: \(String(format: "%8.2f", Double(compactNs) / 1e6)) ms  " +
              "(\(String(format: "%.1f", Double(compactNs) / Double(totalLookups))) ns/lookup)  checksum=\(compactChecksum)  [range=\(compactSize), mem=\(compactSize * 8 / 1024) KB]")
        if let bestMulMask {
            print("  8) MulMask PH:     \(String(format: "%8.2f", Double(mulMaskNs) / 1e6)) ms  " +
                  "(\(String(format: "%.1f", Double(mulMaskNs) / Double(totalLookups))) ns/lookup)  checksum=\(mulMaskChecksum)  [N=\(bestMulMask.tableSize), seed=0x\(String(bestMulMask.seed, radix: 16)), mem=\(bestMulMask.bytes / 1024) KB]")
        }

        _ = binaryChecksum &+ directChecksum &+ linearChecksum &+ chmChecksum &+ chdChecksum &+ mulShiftChecksum &+ mulMaskChecksum &+ compactChecksum
    }
}
