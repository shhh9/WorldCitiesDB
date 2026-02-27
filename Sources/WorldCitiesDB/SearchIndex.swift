import Foundation

/// Bigram inverted index for fast candidate narrowing over city names.
///
/// Each city's name fields (name + ascii name + alternate names, lowercased) are decomposed
/// into 2-character bigrams. A hash map maps each bigram (two unicode scalars packed as UInt64)
/// to a sorted array of city indices. At query time, the query's bigrams are intersected to
/// produce a small candidate set. Callers are responsible for final substring verification.
final class SearchIndex: Sendable {

    /// Bigram (packed UInt64) → sorted array of city indices containing that bigram.
    let bigramIndex: [UInt64: [Int32]]

    /// Whether the bigram index was built.
    var hasBigrams: Bool { !bigramIndex.isEmpty }

    /// Estimated memory usage of the bigram index in bytes.
    var memoryUsageBytes: Int {
        // Int32 = 4 bytes per posting list entry + ~16 bytes per bucket (key + pointer)
        bigramIndex.values.reduce(0) { $0 + $1.count } * 4
            + bigramIndex.count * 16
    }
 
    /// Creates a SearchIndex without building the bigram index.
    /// Use `SearchIndex.build(cities:)` to create one with bigrams.
    init() {
        self.bigramIndex = [:]
    }

    private init(bigramIndex: [UInt64: [Int32]]) {
        self.bigramIndex = bigramIndex
    }

    /// Builds a bigram index from the given cities array.
    static func build(cities: [City]) -> SearchIndex {
        var bigrams: [UInt64: [Int32]] = [:]

        for (i, city) in cities.enumerated() {
            let idx = Int32(i)

            // Build lowercased text for bigram extraction — name + asciiName + alternateNames
            var text = city.name.lowercased() + "\t" + city.asciiName.lowercased()
            for alt in city.alternateNames {
                text += "\t"
                text += alt.lowercased()
            }

            // Extract bigrams in a single pass.
            // Reset at \t boundaries so bigrams don't span across names.
            // Dedup via posting list: since idx increases monotonically,
            // skip if the last entry in the posting list is already idx.
            var prev: UInt32 = 0
            var hasPrev = false
            for scalar in text.unicodeScalars {
                if scalar.value == 0x09 { // \t separator
                    hasPrev = false
                    continue
                }
                if !hasPrev {
                    prev = scalar.value
                    hasPrev = true
                    continue
                }
                let key = packBigram(prev, scalar.value)
                if bigrams[key]?.last != idx {
                    bigrams[key, default: []].append(idx)
                }
                prev = scalar.value
            }
        }

        return SearchIndex(bigramIndex: bigrams)
    }

    /// Returns candidate city indices for a query by intersecting bigram posting lists.
    /// Returns nil when bigrams were not built, for 1-char queries, or for empty queries
    /// (caller should use linear scan). Query must already be lowercased.
    func candidates(for query: String) -> [Int32]? {
        guard hasBigrams else { return nil }
        guard !query.isEmpty else { return nil }

        let scalars = Array(query.unicodeScalars)
        guard scalars.count >= 2 else { return nil }

        return bigramCandidates(scalars: scalars)
    }

    /// Packs two unicode scalar values into a UInt64 bigram key.
    @inline(__always)
    static func packBigram(_ a: UInt32, _ b: UInt32) -> UInt64 {
        UInt64(a) << 32 | UInt64(b)
    }

    /// Returns the bigram posting list for a specific bigram key, or nil if not found.
    func postingList(for bigram: UInt64) -> [Int32]? {
        bigramIndex[bigram]
    }

    /// Converts two unicode scalars to a packed bigram key.
    static func bigramKey(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> UInt64 {
        packBigram(a.value, b.value)
    }

    /// Intersects bigram posting lists, starting from the smallest list for efficiency.
    private func bigramCandidates(scalars: [Unicode.Scalar]) -> [Int32] {
        var lists: [[Int32]] = []
        for j in 0..<(scalars.count - 1) {
            let key = SearchIndex.bigramKey(scalars[j], scalars[j + 1])
            guard let list = bigramIndex[key] else { return [] }
            lists.append(list)
        }

        guard !lists.isEmpty else { return [] }

        // Sort by list size ascending — intersect starting from smallest
        lists.sort { $0.count < $1.count }

        var result = lists[0]
        for k in 1..<lists.count {
            result = intersectSorted(result, lists[k])
            if result.isEmpty { return [] }
        }
        return result
    }

    /// Intersects two sorted Int32 arrays.
    func intersectSorted(_ a: [Int32], _ b: [Int32]) -> [Int32] {
        var result: [Int32] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                result.append(a[i])
                i += 1; j += 1
            } else if a[i] < b[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
