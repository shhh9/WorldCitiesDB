import Foundation

/// Bigram inverted index for fast substring search over city names.
///
/// Each city's searchable text (name + ascii name + alternate names, lowercased) is decomposed
/// into 2-character bigrams. A hash map maps each bigram (two unicode scalars packed as UInt64)
/// to a sorted array of city indices. At query time, the query's bigrams are intersected to
/// produce a small candidate set, then verified with an actual substring check.
///
/// For 1-character queries, falls back to a linear scan of searchText.
final class SearchIndex: Sendable {

    /// Bigram (packed UInt64) → sorted array of city indices containing that bigram.
    let bigramIndex: [UInt64: [Int32]]

    /// Pre-built lowercased searchable text per city for substring verification.
    let searchText: [String]

    /// Packs two unicode scalar values into a UInt64 bigram key.
    @inline(__always)
    static func packBigram(_ a: UInt32, _ b: UInt32) -> UInt64 {
        UInt64(a) << 32 | UInt64(b)
    }

    /// Builds the bigram index from the given cities array.
    init(cities: [City]) {
        var bigrams: [UInt64: [Int32]] = [:]
        var texts: [String] = []
        texts.reserveCapacity(cities.count)

        for (i, city) in cities.enumerated() {
            let idx = Int32(i)

            // Build lowercased searchable text once — name + asciiName + alternateNames
            var text = city.name.lowercased() + "\t" + city.asciiName.lowercased()
            for alt in city.alternateNames {
                text += "\t"
                text += alt.lowercased()
            }
            texts.append(text)

            // Extract bigrams from the already-lowered text in a single pass.
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
                let key = SearchIndex.packBigram(prev, scalar.value)
                if bigrams[key]?.last != idx {
                    bigrams[key, default: []].append(idx)
                }
                prev = scalar.value
            }
        }

        self.bigramIndex = bigrams
        self.searchText = texts
    }

    /// Returns candidate city indices for a query by intersecting bigram posting lists.
    /// For 1-char queries, returns nil (caller should do linear scan).
    /// Returns nil for empty query.
    func candidates(for query: String) -> [Int32]? {
        let q = query.lowercased()
        guard !q.isEmpty else { return nil }

        let scalars = Array(q.unicodeScalars.filter { !$0.properties.isWhitespace })
        guard scalars.count >= 2 else { return nil }

        return bigramCandidates(scalars: scalars)
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

    /// Checks whether the city at the given index contains the query as a substring.
    func matchesSubstring(at index: Int, query: String) -> Bool {
        searchText[index].contains(query)
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
