# WorldCitiesDB

WorldCitiesDB is a Swift package that bundles a ready-to-use GeoNames city
database and fast local search. It ships as a single compressed package
resource, `cities.wcdb`, containing roughly 230,000 records from the GeoNames
`cities500` dataset plus prebuilt search artifacts.

The package has no external package dependencies. At runtime it loads the
bundled database, validates checksums, decodes the city records into the model
type you choose, and exposes population-sorted city data for filtering or
keyword search.

## Features

- Bundled GeoNames `cities500` data, sorted by population descending.
- Admin level 1 and level 2 names from GeoNames admin code tables.
- Full built-in `City` model, including coordinates, feature codes, country
  codes, admin codes, population, elevation, timezone, and modification date.
- Custom city projections with `CityRepresentable`, so apps can decode only the
  fields they need.
- Fast keyword search over primary names and alternate names with Unicode-aware
  folding.
- Prebuilt casefold cache, scalar search index, and packed search fields stored
  inside `cities.wcdb`.
- Incremental search context for search bar style narrowing.
- Pure Swift package targeting Apple platforms.

## Requirements

- Swift tools version 6.0 or newer.
- macOS 13, iOS 16, tvOS 16, or watchOS 9 and newer.

## Installation

Add the package dependency:

```swift
dependencies: [
    .package(url: "https://github.com/shhh9/WorldCitiesDB.git", from: "1.0.15"),
]
```

Then add the library product to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "WorldCitiesDB", package: "WorldCitiesDB"),
    ]
)
```

## Basic Usage

```swift
import WorldCitiesDB

let db = try WorldCitiesDB<City>()

print(db.count)
print(db.metadata.generatedAt)

let tokyo = db.cities.first { $0.geonameId == 1_850_147 }
let japanCities = db.cities.filter { $0.countryCode == "JP" }
let megacities = db.cities.filter { $0.population >= 1_000_000 }
let bayArea = db.cities.filter {
    (37.0...38.0).contains($0.latitude) &&
    (-123.0 ... -121.0).contains($0.longitude)
}
```

`db.cities` is already sorted by population descending.

## Search

Create a `CitySearcher` from the loaded cities and the bundled search artifacts:

```swift
import WorldCitiesDB

let db = try WorldCitiesDB<City>()
let searcher = CitySearcher(
    cities: db.cities,
    casefoldingCache: db.casefoldingCache,
    searchIndex: db.searchIndex,
    packedSearchFields: db.packedSearchFields
)

let results = searcher.search(query: "new york", limit: 10)
for city in results {
    print("\(city.name), \(city.countryCode) pop. \(city.population)")
}
```

Search behavior:

- Searches city name, ASCII name, non-ASCII alternate names, and ASCII
  alternate names.
- Primary name matches rank before alternate-name matches.
- Results preserve database order within each rank, so larger cities usually
  appear first.
- `limit: -1` returns all matches.
- `limit: 0` returns an empty array.
- An empty query returns the first `limit` cities.
- Matching is case-insensitive, diacritic-insensitive, width-insensitive, and
  handles non-ASCII queries such as `münchen`, `京`, and `東京`.

For incremental UI search, reuse a search context:

```swift
let context = searcher.newSearch()

context.update(query: "t")
let broad = context.results(limit: 20)

context.update(query: "to")
let narrowed = context.results(limit: 20)

context.update(query: "tokyo")
let final = context.results(limit: 20)
```

When the query grows from the previous query, `SearchContext` narrows the
existing match set instead of starting from the full database again.

## Custom City Models

Use `CityRepresentable` when your app only needs a subset of fields. String
fields are read lazily from the binary record and are only materialized when
you call their accessor inside `init(from:)`.

```swift
import WorldCitiesDB

struct ClockCity: CityRepresentable, SearchableCity {
    let name: String
    let asciiName: String
    let alternateNames: [String]
    let alternateAsciiNames: [String]
    let countryCode: String
    let admin1Name: String?
    let timezone: String

    init(from fields: borrowing CityFields) {
        name = fields.name()
        asciiName = fields.asciiName()
        alternateNames = fields.alternateNames()
        alternateAsciiNames = fields.alternateAsciiNames()
        countryCode = fields.countryCode()
        admin1Name = fields.admin1Name()
        timezone = fields.timezone() ?? ""
    }

    func matchPrimaryNames(
        _ fastMatcher: (String) -> Bool,
        _ foldMatcher: (String) -> Bool
    ) -> Bool {
        match(name, fastMatcher, foldMatcher) ||
            match(asciiName, fastMatcher, foldMatcher)
    }

    func matchAlternateNames(
        _ fastMatcher: (String) -> Bool,
        _ foldMatcher: (String) -> Bool
    ) -> Bool {
        alternateNames.contains { match($0, fastMatcher, foldMatcher) } ||
            alternateAsciiNames.contains(where: fastMatcher)
    }

    private func match(
        _ value: String,
        _ fastMatcher: (String) -> Bool,
        _ foldMatcher: (String) -> Bool
    ) -> Bool {
        if CasefoldingCache.stringNeedsFoldLookup(value) {
            return foldMatcher(value)
        }
        return fastMatcher(value)
    }
}

let db = try WorldCitiesDB<ClockCity>()
```

If a custom model will not be searched, it only needs to conform to
`CityRepresentable`.

## City Fields

The built-in `City` type contains:

| Property | Type | Description |
| --- | --- | --- |
| `id` | `Int` | Computed alias for `geonameId` for `Identifiable`. |
| `geonameId` | `Int` | GeoNames unique identifier. |
| `name` | `String` | City name. |
| `asciiName` | `String` | City name in plain ASCII. |
| `alternateNames` | `[String]` | Non-ASCII alternate names. |
| `alternateAsciiNames` | `[String]` | ASCII-only alternate names. |
| `latitude` | `Double` | Latitude in decimal degrees, WGS84. |
| `longitude` | `Double` | Longitude in decimal degrees, WGS84. |
| `featureClass` | `String?` | GeoNames feature class. |
| `featureCode` | `String?` | GeoNames feature code. |
| `countryCode` | `String` | ISO 3166-1 alpha-2 country code. |
| `cc2` | `[String]` | Alternate country codes. |
| `admin1Code` | `String?` | First-level administrative division code. |
| `admin1Name` | `String?` | First-level administrative division name. |
| `admin2Code` | `String?` | Second-level administrative division code. |
| `admin2Name` | `String?` | Second-level administrative division name. |
| `admin3Code` | `String?` | Third-level administrative division code. |
| `admin4Code` | `String?` | Fourth-level administrative division code. |
| `population` | `Int` | Population count. |
| `elevation` | `Int?` | Elevation in meters. |
| `dem` | `Int?` | Digital elevation model value. |
| `timezone` | `String?` | IANA timezone identifier. |
| `modificationDate` | `Date?` | GeoNames modification date. |

## Database Generation

The checked-in database lives at:

```text
Sources/WorldCitiesDB/Resources/cities.wcdb
```

To rebuild it locally:

```bash
swift run BuildDB
```

By default, `BuildDB` writes `Sources/WorldCitiesDB/Resources/cities.wcdb`.
You can also pass an output file or directory:

```bash
swift run BuildDB /tmp/cities.wcdb
swift run BuildDB /tmp/output-directory
```

`BuildDB` downloads:

- `cities500.zip`
- `admin1CodesASCII.txt`
- `admin2Codes.txt`

It parses the GeoNames data, separates ASCII and non-ASCII alternate names,
adds admin names, sorts cities by population, builds search artifacts, compresses
the city and search payloads with LZ4, stores metadata, and writes checksums for
load-time validation.

The GitHub Actions workflow in `.github/workflows/update-db.yml` runs weekly on
Sundays at 00:00 UTC and can also be started manually. If the generated database
changes, it commits the new `cities.wcdb` file and creates the next patch tag.

## Development Commands

Run tests:

```bash
swift test
```

Run the demo:

```bash
swift run -c release Demo
```

Run the search benchmark:

```bash
swift run -c release Benchmark
```

Write the benchmark report to the tracked result file:

```bash
swift run -c release Benchmark --markdown BENCHMARK.md
```

Run the fold lookup benchmark:

```bash
swift run -c release Benchmark --fold-lookup
```

The benchmark compares four modes: no indexes, casefold cache only, search index
only, and both prebuilt structures together.

## Benchmark Performance

The latest generated release benchmark report is tracked in
[BENCHMARK.md](BENCHMARK.md). It includes average, minimum, and maximum time per
query by search mode, plus detailed per-query timing for all benchmark limits.

The weekly GitHub Actions workflow rebuilds the database, runs:

```bash
swift run -c release Benchmark --markdown BENCHMARK.md
```

and commits the updated benchmark report on every run. Database changes are
committed in the same workflow run when GeoNames data changes.

## File Format

`cities.wcdb` contains:

- File header and version.
- JSON metadata.
- Compressed city payload.
- Compressed search artifact payload.
- CRC32 fingerprints for city data and search data.

The city payload stores length-prefixed binary records. `CityFields` scans field
boundaries without allocating all strings up front, which allows custom
projections to avoid unused fields.

The search artifact payload stores:

- `CasefoldingCache`: non-ASCII scalar fold expansions used by Unicode-aware
  matching.
- `SearchIndex`: per-scalar candidate index with bitmap storage for frequent
  scalars and varint deltas for sparse scalars.
- `PackedSearchFields`: contiguous search strings and field spans used during
  matching.

Runtime loading does not rebuild these structures when the bundled artifacts
match the city count and schema.

## Data Source And License

City and admin data come from [GeoNames](https://www.geonames.org/) and are
licensed by GeoNames under the
[Creative Commons Attribution 4.0 License](https://creativecommons.org/licenses/by/4.0/).

WorldCitiesDB source code is released under the MIT license. See `LICENSE`.
