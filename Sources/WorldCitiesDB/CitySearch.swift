import Foundation

/// Incremental search session for search-bar style progressive narrowing.
///
/// Maintains internal state so that appending characters to the query
/// incrementally narrows the candidate set using new bigrams, while deleting
/// characters recomputes from scratch. Results are verified with substring matching.
///
/// ```swift
/// let search = db.newSearch()
/// search.update(query: "n")        // linear scan for 1-char
/// search.update(query: "ne")       // bigram candidates for "ne"
/// search.update(query: "new")      // intersect new bigram "ew" with candidates
/// search.update(query: "ne")       // user deleted 'w' → recompute from "ne"
/// let results = search.results(limit: 20)  // top 20 by population
/// ```
public final class CitySearch {
    private let cities: [City]
    private let index: SearchIndex
    private var currentQuery: String = ""
    private var currentCandidates: [Int32]?

    init(cities: [City], index: SearchIndex) {
        self.cities = cities
        self.index = index
    }

    /// Updates the search with a new query string.
    ///
    /// If the new query extends the previous one by one character and both have 2+ chars,
    /// incrementally intersects only the new bigram's posting list with current candidates.
    /// Otherwise recomputes from scratch.
    public func update(query: String) {
        let normalizedNew = query.lowercased().filter { !$0.isWhitespace }
        let normalizedOld = currentQuery

        if normalizedNew.isEmpty {
            currentQuery = ""
            currentCandidates = nil
            return
        }

        if normalizedNew.count < 2 {
            // 1-char query: no bigram candidates, will do linear scan in results()
            currentQuery = normalizedNew
            currentCandidates = nil
            return
        }

        if normalizedNew.hasPrefix(normalizedOld) && normalizedOld.count >= 2,
           let existing = currentCandidates {
            // Incremental: intersect new bigram(s) with existing candidates
            let oldScalars = Array(normalizedOld.unicodeScalars)
            let newScalars = Array(normalizedNew.unicodeScalars)

            var candidates = existing
            // For each new bigram formed at the boundary and beyond
            let startIdx = max(oldScalars.count - 1, 0)
            for j in startIdx..<(newScalars.count - 1) {
                let key = SearchIndex.bigramKey(newScalars[j], newScalars[j + 1])
                guard let list = index.postingList(for: key) else {
                    currentCandidates = []
                    currentQuery = normalizedNew
                    return
                }
                candidates = index.intersectSorted(candidates, list)
                if candidates.isEmpty { break }
            }
            currentCandidates = candidates
        } else {
            // Full recompute
            currentCandidates = index.candidates(for: normalizedNew)
        }

        currentQuery = normalizedNew
    }

    /// Returns the top `limit` cities matching the current query, sorted by population (descending).
    ///
    /// Since the cities array is pre-sorted by population, we iterate in order
    /// and pick the first `limit` verified matches from the candidate set.
    public func results(limit: Int = 20) -> [City] {
        let query = currentQuery
        guard !query.isEmpty else {
            return Array(cities.prefix(limit))
        }

        if query.count < 2 {
            // 1-char: linear scan (cities are already sorted by population)
            var matches: [City] = []
            matches.reserveCapacity(limit)
            for i in 0..<cities.count {
                if index.matchesSubstring(at: i, query: query) {
                    matches.append(cities[i])
                    if matches.count >= limit { break }
                }
            }
            return matches
        }

        guard let candidateList = currentCandidates else {
            return Array(cities.prefix(limit))
        }

        // Build a set for O(1) membership checks
        let candidateSet = Set(candidateList)

        var matches: [City] = []
        matches.reserveCapacity(limit)

        for i in 0..<cities.count {
            if candidateSet.contains(Int32(i)) && index.matchesSubstring(at: i, query: query) {
                matches.append(cities[i])
                if matches.count >= limit { break }
            }
        }

        return matches
    }
}
