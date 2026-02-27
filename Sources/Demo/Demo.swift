import Foundation
import WorldCitiesDB

/// Returns "CityName (CC)" if the query matched name/asciiName,
/// or "CityName (CC) via «altName»" if it matched an alternate name.
func describeMatch(_ result: SearchResult) -> String {
    let city = result.city
    let base = "\(city.name) (\(city.countryCode))"

    if result.matchedPrimaryName {
        return base
    }

    if let first = result.matchedAlternateNames.first {
        return "\(base) via \"\(first)\""
    }

    return base
}

func printCity(_ city: City, indent: String = "  ") {
    let altNames = city.alternateNames.isEmpty ? "(none)" :
        city.alternateNames.prefix(5).joined(separator: ", ")
        + (city.alternateNames.count > 5 ? " (+\(city.alternateNames.count - 5) more)" : "")
    print("\(indent)\(city.name) | ascii: \(city.asciiName) | alt: \(altNames)")
    print("\(indent)  cc: \(city.countryCode) | pop: \(city.population) | tz: \(city.timezone ?? "?") | id: \(city.geonameId)")
}

@main
struct Demo {
    static func main() throws {
        // 1. Load database
        var start = CFAbsoluteTimeGetCurrent()
        let db = try WorldCitiesDB()
        let totalTime = CFAbsoluteTimeGetCurrent() - start
        print("Total load: \(String(format: "%.3f", totalTime))s\n")

        // 2. Search performance (1-char queries use deferred scan, 2+ char use bigram index)
        // Note: first 2+ char query triggers lazy bigram index build
        let testQueries = ["x", "yo", "tok", "beij", "paris", "new york", "京", "münchen"]
        print("=== Search Performance ===")
        print("Query         Time        Results")
        print(String(repeating: "-", count: 45))

        for query in testQueries {
            start = CFAbsoluteTimeGetCurrent()
            let results = db.search(keyword: query)
            let time = CFAbsoluteTimeGetCurrent() - start
            let q = query.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("\(q)  \(String(format: "%8.3fms", time * 1000))  \(String(format: "%5d", results.count))")
        }
        print()

        // 3. Keyword search with detailed results
        for query in ["york", "tokyo", "münchen"] {
            start = CFAbsoluteTimeGetCurrent()
            let results = db.search(keyword: query, limit: 5)
            let searchTime = CFAbsoluteTimeGetCurrent() - start
            let total = db.search(keyword: query)
            print("=== Search: \"\(query)\" — \(total.count) total, showing top \(results.count) (\(String(format: "%.3f", searchTime * 1000))ms) ===")
            for result in results {
                printCity(result.city)
            }
            print()
        }

        // 4. Progressive search refinement
        print("=== Progressive search ===")
        let search = db.newSearch()

        for query in ["t", "to", "tok", "toky", "tokyo"] {
            start = CFAbsoluteTimeGetCurrent()
            search.update(query: query)
            let all = search.results(limit: -1)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let names = all.prefix(5).map { describeMatch($0) }.joined(separator: ", ")
            print("  \"\(query)\" → \(all.count) total: \(names)  (\(String(format: "%.3f", elapsed * 1000))ms)")
        }

        // 5. Backspace simulation
        print("\n=== Backspace: \"tokyo\" → \"tok\" ===")
        start = CFAbsoluteTimeGetCurrent()
        search.update(query: "tok")
        let backspaceResults = search.results(limit: 5)
        let backspaceTime = CFAbsoluteTimeGetCurrent() - start
        print("  \(backspaceResults.count) results shown:")
        for result in backspaceResults {
            printCity(result.city)
        }
        print("  (\(String(format: "%.3f", backspaceTime * 1000))ms)\n")

        // 6. Country filter
        print("=== Cities in Japan (top 5 by population) ===")
        start = CFAbsoluteTimeGetCurrent()
        let jpCities = db.cities(inCountry: "JP")
        let countryTime = CFAbsoluteTimeGetCurrent() - start
        print("  \(jpCities.count) total cities in JP:")
        for city in jpCities.prefix(5) {
            printCity(city)
        }
        print("  (\(String(format: "%.3f", countryTime * 1000))ms)\n")

        // 7. Megacities
        print("=== Megacities (population >= 10M) ===")
        start = CFAbsoluteTimeGetCurrent()
        let megacities = db.cities(minPopulation: 10_000_000)
        let megaTime = CFAbsoluteTimeGetCurrent() - start
        print("  \(megacities.count) megacities:")
        for city in megacities {
            printCity(city)
        }
        print("  (\(String(format: "%.3f", megaTime * 1000))ms)\n")

        // 8. Bounding box (Tokyo area)
        print("=== Bounding box: Tokyo area ===")
        start = CFAbsoluteTimeGetCurrent()
        let nearby = db.cities(
            minLatitude: 35.5, maxLatitude: 35.8,
            minLongitude: 139.5, maxLongitude: 139.9
        )
        let bboxTime = CFAbsoluteTimeGetCurrent() - start
        print("  \(nearby.count) cities in box, showing top 5:")
        for city in nearby.prefix(5) {
            print("  \(city.name) — \(city.latitude), \(city.longitude)")
        }
        print("  (\(String(format: "%.3f", bboxTime * 1000))ms)\n")

        // 9. ID lookup
        print("=== Lookup by GeoNames ID: 5128581 (New York City) ===")
        start = CFAbsoluteTimeGetCurrent()
        let nyc = db.city(id: 5128581)
        let idTime = CFAbsoluteTimeGetCurrent() - start
        if let nyc {
            printCity(nyc)
        }
        print("  (\(String(format: "%.3f", idTime * 1000))ms)")
    }
}
