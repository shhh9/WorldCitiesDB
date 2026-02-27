import Compression
import Foundation

/// Provides read-only access to the bundled world cities database.
public final class WorldCitiesDB: Sendable {

    /// All cities sorted by population (descending).
    private let cities: [City]

    /// Bigram inverted index for keyword search, or nil when index is disabled.
    private let searchIndex: SearchIndex

    /// Lookup table from geonameId to array index.
    private let idIndex: [Int: Int]

    /// Creates a new instance using the bundled cities data.
    public convenience init() throws {
        guard let url = Bundle.module.url(forResource: "cities", withExtension: "lz4", subdirectory: "Resources") else {
            fatalError("cities.lz4 not found in bundle. Run BuildDB to generate it.")
        }
        try self.init(data: Data(contentsOf: url))
    }

    /// Creates an instance from a custom data file path.
    public convenience init(path: String) throws {
        try self.init(data: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Creates an instance from pre-loaded LZ4-compressed binary data.
    public init(data: Data) throws {
        var start = CFAbsoluteTimeGetCurrent()
        self.cities = try Self.decodeBinary(from: data)
        let decodeTime = CFAbsoluteTimeGetCurrent() - start
        print("[\(Self.self)] Binary decode: \(String(format: "%.3f", decodeTime))s (\(cities.count) cities)")

        var idIdx: [Int: Int] = [:]
        idIdx.reserveCapacity(cities.count)
        for (i, city) in cities.enumerated() {
            idIdx[city.geonameId] = i
        }
        self.idIndex = idIdx

        start = CFAbsoluteTimeGetCurrent()
        self.searchIndex = SearchIndex.build(cities: cities)
        let indexTime = CFAbsoluteTimeGetCurrent() - start
        print("[\(Self.self)] Index build: \(String(format: "%.3f", indexTime))s (\(searchIndex.memoryUsageBytes / 1024)KB)")
    }

    // MARK: - Binary Decoding

    private static func decodeBinary(from fileData: Data) throws -> [City] {
        guard fileData.count > 8 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "File too small"))
        }

        // Read 8-byte uncompressed size prefix
        let uncompressedSize: Int = fileData.withUnsafeBytes { ptr in
            Int(ptr.loadUnaligned(as: UInt64.self).littleEndian)
        }

        // Decompress LZ4
        let compressedData = fileData.dropFirst(8)
        var decompressed = Data(count: uncompressedSize)

        let decodedSize = compressedData.withUnsafeBytes { srcPtr in
            decompressed.withUnsafeMutableBytes { dstPtr in
                compression_decode_buffer(
                    dstPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    uncompressedSize,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    compressedData.count,
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }

        guard decodedSize == uncompressedSize else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "LZ4 decompression failed: expected \(uncompressedSize), got \(decodedSize)"
            ))
        }

        // Parse binary payload
        return try decompressed.withUnsafeBytes { buffer in
            var reader = BinaryReader(buffer: buffer)

            // Header
            let magic = reader.readUInt32()
            guard magic == 0x4244_4357 else { // "WCDB" as little-endian UInt32
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Invalid magic: \(String(magic, radix: 16))"
                ))
            }
            let version = reader.readUInt32()
            guard version == 1 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Unsupported version: \(version)"
                ))
            }
            let cityCount = Int(reader.readUInt32())

            var cities: [City] = []
            cities.reserveCapacity(cityCount)

            for _ in 0..<cityCount {
                let geonameId = Int(reader.readInt64())
                let name = reader.readString()
                let asciiName = reader.readString()
                let alternateNames = reader.readStringArray()
                let latitude = reader.readDouble()
                let longitude = reader.readDouble()
                let featureClass = reader.readOptionalString()
                let featureCode = reader.readOptionalString()
                let countryCode = reader.readString()
                let cc2 = reader.readStringArray()
                let admin1Code = reader.readOptionalString()
                let admin2Code = reader.readOptionalString()
                let admin3Code = reader.readOptionalString()
                let admin4Code = reader.readOptionalString()
                let population = Int(reader.readInt64())
                let elevation = reader.readOptionalInt()
                let dem = reader.readOptionalInt()
                let timezone = reader.readOptionalString()
                let modificationDate = reader.readOptionalDate()

                cities.append(City(
                    geonameId: geonameId,
                    name: name,
                    asciiName: asciiName,
                    alternateNames: alternateNames,
                    latitude: latitude,
                    longitude: longitude,
                    featureClass: featureClass,
                    featureCode: featureCode,
                    countryCode: countryCode,
                    cc2: cc2,
                    admin1Code: admin1Code,
                    admin2Code: admin2Code,
                    admin3Code: admin3Code,
                    admin4Code: admin4Code,
                    population: population,
                    elevation: elevation,
                    dem: dem,
                    timezone: timezone,
                    modificationDate: modificationDate
                ))
            }

            return cities
        }
    }

    // MARK: - Search

    /// Searches cities by keyword (substring match on name and alternate names).
    /// Uses the bigram inverted index as a fast pre-filter, then verifies with substring matching.
    /// - Parameter limit: Maximum number of results. Use `-1` (default) for all results.
    /// - Parameter nameFirst: When `true` (default), results matching name/asciiName are returned
    ///   before results matching only in alternateNames. Within each group, sorted by population.
    public func search(keyword: String, limit: Int = -1, nameFirst: Bool = true) -> [SearchResult] {
        let ctx = newSearch()
        ctx.update(query: keyword)
        return ctx.results(limit: limit, nameFirst: nameFirst)
    }

    /// Creates a new search context for progressive query refinement.
    public func newSearch() -> SearchContext {
        SearchContext(cities: cities, index: searchIndex)
    }

    /// Checks whether any of the city's name fields contain the query as a substring.
    /// Query must already be lowercased. Checks asciiName first (always ASCII, fastest).
    static func matchesCity(_ city: City, query: String) -> Bool {
        containsIgnoringCase(city.asciiName, query) ||
        containsIgnoringCase(city.name, query) ||
        city.alternateNames.contains { containsIgnoringCase($0, query) }
    }

    /// Matches a city against the query and builds a SearchResult in one pass.
    /// Returns nil if the city doesn't match. Avoids redundant containsIgnoringCase calls
    /// compared to calling matchesCity + buildResult separately.
    static func matchAndBuild(_ city: City, query: String) -> SearchResult? {
        let matchedAsciiName = containsIgnoringCase(city.asciiName, query)
        let matchedName = containsIgnoringCase(city.name, query)
        let matchedAlternateNames = city.alternateNames.filter { containsIgnoringCase($0, query) }
        guard matchedAsciiName || matchedName || !matchedAlternateNames.isEmpty else { return nil }
        return SearchResult(
            city: city,
            matchedName: matchedName,
            matchedAsciiName: matchedAsciiName,
            matchedAlternateNames: matchedAlternateNames
        )
    }

    /// Case-insensitive substring search optimized for ASCII strings.
    /// The `query` must already be lowercased.
    /// Uses direct UTF-8 byte comparison for ASCII (no heap allocation).
    /// When the query is pure ASCII, non-ASCII haystack bytes are skipped (they can
    /// never match). Only falls back to Foundation when the query itself is non-ASCII.
    static func containsIgnoringCase(_ haystack: String, _ query: String) -> Bool {
        var h = haystack
        var q = query
        return h.withUTF8 { hBuf in
            q.withUTF8 { qBuf in
                let hLen = hBuf.count
                let qLen = qBuf.count
                guard qLen > 0 else { return true }
                guard qLen <= hLen else { return false }

                // Check if query is pure ASCII
                var queryIsASCII = true
                for k in 0..<qLen {
                    if qBuf[k] >= 0x80 { queryIsASCII = false; break }
                }

                let limit = hLen - qLen
                for i in 0...limit {
                    let hByte = hBuf[i]
                    if hByte >= 0x80 {
                        if queryIsASCII { continue }
                        return haystack.lowercased().contains(query)
                    }
                    let hLower = (hByte >= 0x41 && hByte <= 0x5A) ? hByte &+ 0x20 : hByte
                    if hLower == qBuf[0] {
                        var matched = true
                        for j in 1..<qLen {
                            let hb = hBuf[i + j]
                            if hb >= 0x80 {
                                if queryIsASCII { matched = false; break }
                                return haystack.lowercased().contains(query)
                            }
                            let hl = (hb >= 0x41 && hb <= 0x5A) ? hb &+ 0x20 : hb
                            if hl != qBuf[j] {
                                matched = false
                                break
                            }
                        }
                        if matched { return true }
                    }
                }
                return false
            }
        }
    }

    // MARK: - Queries

    /// Returns all cities sorted by population (descending).
    /// Warning: this returns ~185,000 entries.
    public func allCities() -> [City] {
        cities
    }

    /// Returns cities in a specific country (ISO-3166 2-letter code).
    public func cities(inCountry countryCode: String) -> [City] {
        cities.filter { $0.countryCode == countryCode }
    }

    /// Returns cities with population greater than or equal to the given value,
    /// sorted by population (descending).
    public func cities(minPopulation: Int) -> [City] {
        cities.filter { $0.population >= minPopulation }
    }

    /// Returns a city by its GeoNames ID.
    public func city(id: Int) -> City? {
        guard let idx = idIndex[id] else { return nil }
        return cities[idx]
    }

    /// Returns cities within a bounding box.
    public func cities(
        minLatitude: Double, maxLatitude: Double,
        minLongitude: Double, maxLongitude: Double
    ) -> [City] {
        cities.filter {
            $0.latitude >= minLatitude && $0.latitude <= maxLatitude &&
            $0.longitude >= minLongitude && $0.longitude <= maxLongitude
        }
    }

    /// Returns the total number of cities.
    public func count() -> Int {
        cities.count
    }
}

// MARK: - BinaryReader

private struct BinaryReader {
    let buffer: UnsafeRawBufferPointer
    var offset: Int = 0

    mutating func readUInt32() -> UInt32 {
        let value = buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        offset += 4
        return value
    }

    mutating func readInt64() -> Int64 {
        let value = buffer.loadUnaligned(fromByteOffset: offset, as: Int64.self).littleEndian
        offset += 8
        return value
    }

    mutating func readDouble() -> Double {
        let bits = buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
        offset += 8
        return Double(bitPattern: bits)
    }

    mutating func readString() -> String {
        let length = Int(readUInt32())
        let str = String(unsafeUninitializedCapacity: length) { buf in
            buf.baseAddress!.update(from: buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: length)
            return length
        }
        offset += length
        return str
    }

    mutating func readOptionalString() -> String? {
        let flag = buffer.load(fromByteOffset: offset, as: UInt8.self)
        offset += 1
        return flag == 1 ? readString() : nil
    }

    mutating func readStringArray() -> [String] {
        let count = Int(readUInt32())
        var result: [String] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(readString())
        }
        return result
    }

    mutating func readOptionalInt() -> Int? {
        let flag = buffer.load(fromByteOffset: offset, as: UInt8.self)
        offset += 1
        return flag == 1 ? Int(readInt64()) : nil
    }

    mutating func readOptionalDate() -> Date? {
        let flag = buffer.load(fromByteOffset: offset, as: UInt8.self)
        offset += 1
        return flag == 1 ? Date(timeIntervalSinceReferenceDate: readDouble()) : nil
    }
}
