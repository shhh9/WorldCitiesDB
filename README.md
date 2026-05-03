# WorldCitiesDB

A Swift package providing a pre-built database of ~185,000 world cities from the [GeoNames](https://www.geonames.org/) cities500 dataset. Includes all cities with a population greater than 500 or that serve as seats of administrative divisions.

Uses a pure Swift data model with a character-level inverted index for fast keyword search — no external dependencies required.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/shhh9/WorldCitiesDB.git", from: "1.0.0"),
]
```

Then add `WorldCitiesDB` to your target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "WorldCitiesDB", package: "WorldCitiesDB"),
    ]
)
```

## Usage

```swift
import WorldCitiesDB

let db = try WorldCitiesDB<City>()

// Search cities by keyword (searches name + alternate names, sorted by population)
let searcher = CitySearcher(
    cities: db.cities,
    casefoldingCache: db.casefoldingCache,
    searchIndex: db.searchIndex,
    packedSearchFields: db.packedSearchFields
)

let results = searcher.search(query: "york", limit: 10)
for city in results {
    print("\(city.name), \(city.countryCode) — pop. \(city.population)")
}

// Incremental search for search bar UI
let search = searcher.newSearch()
search.update(query: "n")       // narrows to cities matching 'n'
search.update(query: "ne")      // further narrows with 'e'
search.update(query: "new")     // further narrows with 'w'
search.update(query: "ne")      // user deleted 'w' → recomputes from "ne"
let top = search.results(limit: 20)

// Get all cities in a country (ISO-3166 2-letter code)
let japanCities = db.cities.filter { $0.countryCode == "JP" }

// Find large cities
let megacities = db.cities.filter { $0.population >= 1_000_000 }

// Look up a city by GeoNames ID
let tokyo = db.cities.first { $0.geonameId == 1_850_147 }

// Find cities in a bounding box
let nearby = db.cities.filter {
    (35.5...36.0).contains($0.latitude) &&
    (139.5...140.0).contains($0.longitude)
}

// Total count
let total = db.count
```

## Quick Start (Build & Demo)

Build the bundled city database file (downloads ~30 MB from GeoNames, takes a minute or so):

```bash
swift run BuildDB
```

Run the demo in release mode to verify everything works:

```bash
swift run -c release Demo
```

The demo exercises full and custom city projections, keyword search, incremental search, and memory reporting.

Run the benchmark to compare search performance with and without each search structure:

```bash
swift run -c release Benchmark
```

It automatically runs the full suite (`none`, `casefold`, `index`, `both`) for limits `-1`, `100`, `50`, and `20`, prints each query result immediately, then prints per-mode totals and speedups.

## City Struct

The `City` struct contains the following properties:

| Property | Type | Description |
|---|---|---|
| `geonameId` | `Int` | GeoNames unique identifier |
| `name` | `String` | City name (UTF-8) |
| `asciiName` | `String` | City name in plain ASCII |
| `alternateNames` | `[String]` | Alternate names (empty array if none) |
| `latitude` | `Double` | Latitude in decimal degrees (WGS84) |
| `longitude` | `Double` | Longitude in decimal degrees (WGS84) |
| `featureClass` | `String?` | GeoNames [feature class](https://www.geonames.org/export/codes.html) |
| `featureCode` | `String?` | GeoNames [feature code](https://www.geonames.org/export/codes.html) |
| `countryCode` | `String` | ISO-3166 2-letter country code |
| `cc2` | `[String]` | Alternate country codes (empty array if none) |
| `admin1Code` | `String?` | First-level administrative division code |
| `admin2Code` | `String?` | Second-level administrative division code |
| `admin3Code` | `String?` | Third-level administrative division code |
| `admin4Code` | `String?` | Fourth-level administrative division code |
| `population` | `Int` | Population count |
| `elevation` | `Int?` | Elevation in meters |
| `dem` | `Int?` | Digital elevation model value (SRTM3/GTOPO30) |
| `timezone` | `String?` | IANA timezone ID |
| `modificationDate` | `Date?` | Date of last modification |

## How It Works

A GitHub Actions workflow runs weekly to download the latest [cities500](https://download.geonames.org/export/dump/) data from GeoNames, parse the tab-separated file, and build one package resource:

- `cities.wcdb`: canonical city records, metadata, and precomputed search artifacts.

At runtime, `cities.wcdb` is decoded as a single artifact. The prebuilt casefold cache, scalar search index, and packed search fields are required to be present and checksum-validated; runtime loading does not rebuild search structures.

## Data Source

City data is sourced from [GeoNames](https://www.geonames.org/) and is licensed under the [Creative Commons Attribution 4.0 License](https://creativecommons.org/licenses/by/4.0/).
