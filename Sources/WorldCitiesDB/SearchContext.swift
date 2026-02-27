import Foundation

/// Stateful search context for progressive query refinement.
///
/// Caches matched city indices so that extending a query (prefix match) narrows
/// the cached set instead of rescanning from scratch. When the new query is not
/// a prefix of the previous one, a full recompute is performed.
///
/// One-character queries are deferred: no scanning happens until `results()` is
/// called. This avoids expensive full scans when the user quickly types a second
/// character (e.g. "t" → "to") before requesting results.
///
/// ```swift
/// let ctx = db.newSearch()
/// ctx.update(query: "new")
/// ctx.update(query: "new yo")       // filters cached matches
/// ctx.update(query: "new york")     // filters further
/// ctx.update(query: "paris")        // not a prefix → full recompute
/// let results = ctx.results(limit: 20)
/// ```
public final class SearchContext {
    private let cities: [City]
    private let index: SearchIndex

    private var lastQuery: String = ""
    /// Indices into `cities` of verified matches for lastQuery, in population order.
    private var lastMatches: [Int32] = []
    /// Bigram-narrowed candidate indices (only maintained when index has bigrams).
    private var lastBigramCandidates: [Int32]?

    /// Whether the last query is a deferred 1-char query (no scan performed yet).
    private var isPendingScan: Bool {
        lastQuery.unicodeScalars.count == 1 && lastMatches.isEmpty
    }

    init(cities: [City], index: SearchIndex) {
        self.cities = cities
        self.index = index
    }

    /// Updates the search with a new query string.
    ///
    /// If the new query extends the previous one (prefix), the cached matches
    /// are filtered rather than rescanning all cities. One-character queries
    /// are deferred — no scanning happens until `results()` is called.
    public func update(query rawQuery: String) {
        let query = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        defer { lastQuery = query }

        // Empty or 1-char query: clear cached state. 1-char scans are deferred to results().
        if query.unicodeScalars.count <= 1 {
            lastMatches = []
            lastBigramCandidates = nil
            return
        }

        // Incremental path: new query extends the previous one
        if !lastQuery.isEmpty && query.hasPrefix(lastQuery) && query != lastQuery {
            if isPendingScan {
                // Previous was a deferred 1-char query — use bigram index directly
                if let candidates = index.candidates(for: query) {
                    lastBigramCandidates = candidates
                    var matches: [Int32] = []
                    for i in candidates {
                        if WorldCitiesDB.matchesCity(cities[Int(i)], query: query) {
                            matches.append(i)
                        }
                    }
                    matches.sort { cities[Int($0)].population > cities[Int($1)].population }
                    lastMatches = matches
                    return
                }
                // Fallback: full recompute
                fullRecompute(query)
                return
            }

            if index.hasBigrams, var candidates = lastBigramCandidates {
                // Narrow existing bigram candidates with new bigrams
                let oldScalars = Array(lastQuery.unicodeScalars)
                let newScalars = Array(query.unicodeScalars)
                let startIdx = max(oldScalars.count - 1, 0)
                for j in startIdx..<(newScalars.count - 1) {
                    let key = SearchIndex.bigramKey(newScalars[j], newScalars[j + 1])
                    guard let list = index.postingList(for: key) else {
                        lastBigramCandidates = []
                        lastMatches = []
                        return
                    }
                    candidates = index.intersectSorted(candidates, list)
                    if candidates.isEmpty {
                        lastBigramCandidates = []
                        lastMatches = []
                        return
                    }
                }
                lastBigramCandidates = candidates
                // Verify narrowed bigram candidates
                var matches: [Int32] = []
                for i in candidates {
                    if WorldCitiesDB.matchesCity(cities[Int(i)], query: query) {
                        matches.append(i)
                    }
                }
                matches.sort { cities[Int($0)].population > cities[Int($1)].population }
                lastMatches = matches
                return
            } else if let candidates = index.candidates(for: query) {
                // Previous query had no bigram candidates — use bigram index directly
                lastBigramCandidates = candidates
                var matches: [Int32] = []
                for i in candidates {
                    if WorldCitiesDB.matchesCity(cities[Int(i)], query: query) {
                        matches.append(i)
                    }
                }
                matches.sort { cities[Int($0)].population > cities[Int($1)].population }
                lastMatches = matches
                return
            } else {
                // No index: filter cached matches against the longer query
                lastMatches = lastMatches.filter {
                    WorldCitiesDB.matchesCity(cities[Int($0)], query: query)
                }
                return
            }
        }

        // Full recompute
        fullRecompute(query)
    }

    /// Full recompute using bigram index or linear scan.
    private func fullRecompute(_ query: String) {
        if let candidates = index.candidates(for: query) {
            lastBigramCandidates = candidates
            var matches: [Int32] = []
            for i in candidates {
                if WorldCitiesDB.matchesCity(cities[Int(i)], query: query) {
                    matches.append(i)
                }
            }
            matches.sort { cities[Int($0)].population > cities[Int($1)].population }
            lastMatches = matches
        } else {
            lastBigramCandidates = nil
            var matches: [Int32] = []
            for i in 0..<cities.count {
                if WorldCitiesDB.matchesCity(cities[i], query: query) {
                    matches.append(Int32(i))
                }
            }
            // cities is already sorted by population, so matches preserve that order
            lastMatches = matches
        }
    }

    /// Returns search results matching the current query.
    /// - Parameter limit: Maximum number of results. Use `-1` for all results.
    /// - Parameter nameFirst: When `true` (default), results matching name/asciiName appear
    ///   before results matching only in alternateNames. Within each group, sorted by population.
    public func results(limit: Int = 20, nameFirst: Bool = true) -> [SearchResult] {
        let query = lastQuery
        let effectiveLimit = limit < 0 ? Int.max : limit

        guard !query.isEmpty else {
            return Array(cities.prefix(effectiveLimit).map {
                SearchResult(city: $0, matchedName: false, matchedAsciiName: false, matchedAlternateNames: [])
            })
        }

        // Handle deferred 1-char scan with early stop
        if isPendingScan {
            if nameFirst {
                var nameResults: [SearchResult] = []
                var altResults: [SearchResult] = []
                var indices: [Int32] = []
                for i in 0..<cities.count {
                    if let result = WorldCitiesDB.matchAndBuild(cities[i], query: query) {
                        indices.append(Int32(i))
                        if result.matchedPrimaryName {
                            nameResults.append(result)
                        } else {
                            altResults.append(result)
                        }
                        if nameResults.count >= effectiveLimit && altResults.count >= effectiveLimit {
                            break
                        }
                    }
                }
                lastMatches = indices
                let remaining = max(0, effectiveLimit - nameResults.count)
                return Array(nameResults.prefix(effectiveLimit)) + Array(altResults.prefix(remaining))
            } else {
                var results: [SearchResult] = []
                var indices: [Int32] = []
                for i in 0..<cities.count {
                    if let result = WorldCitiesDB.matchAndBuild(cities[i], query: query) {
                        indices.append(Int32(i))
                        results.append(result)
                        if results.count >= effectiveLimit { break }
                    }
                }
                lastMatches = indices
                return results
            }
        }

        if nameFirst {
            var nameResults: [SearchResult] = []
            var altResults: [SearchResult] = []
            for idx in lastMatches {
                let result = WorldCitiesDB.matchAndBuild(cities[Int(idx)], query: query)!
                if result.matchedPrimaryName {
                    nameResults.append(result)
                } else {
                    altResults.append(result)
                }
                if nameResults.count >= effectiveLimit && altResults.count >= effectiveLimit {
                    break
                }
            }
            let remaining = max(0, effectiveLimit - nameResults.count)
            return Array(nameResults.prefix(effectiveLimit)) + Array(altResults.prefix(remaining))
        }

        return Array(lastMatches.prefix(effectiveLimit).map {
            WorldCitiesDB.matchAndBuild(cities[Int($0)], query: query)!
        })
    }
}
