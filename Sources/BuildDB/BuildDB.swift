import Compression
import Foundation
import WorldCitiesDB

func printCity(_ city: City, indent: String = "  ") {
    print("\(indent)id: \(city.geonameId)")
    for child in Mirror(reflecting: city).children {
        guard let label = child.label else { continue }
        print("\(indent)\(label): \(String(describing: child.value))")
    }
}

@main
struct BuildDB {
    static func main() async throws {
        let fileManager = FileManager.default

        // Determine output path
        let outputPath: String
        if CommandLine.arguments.count > 1 {
            outputPath = CommandLine.arguments[1]
        } else {
            // Default: write to Sources/WorldCitiesDB/Resources/cities.lz4
            let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            let resourcesDir = scriptDir
                .deletingLastPathComponent()
                .appendingPathComponent("WorldCitiesDB")
                .appendingPathComponent("Resources")
            outputPath = resourcesDir.appendingPathComponent("cities.lz4").path
        }

        print("Output path: \(outputPath)")

        // 1. Create temp workspace
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // 2. Download and cache admin code tables first
        let admin1Path = tempDir.appendingPathComponent("admin1CodesASCII.txt")
        print("Downloading admin1CodesASCII.txt...")
        let admin1Curl = Process()
        admin1Curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        admin1Curl.arguments = ["-#", "-L", "-o", admin1Path.path,
                                "https://download.geonames.org/export/dump/admin1CodesASCII.txt"]
        try admin1Curl.run()
        admin1Curl.waitUntilExit()
        guard admin1Curl.terminationStatus == 0 else {
            fatalError("Failed to download admin1CodesASCII.txt")
        }
        let admin1Lookup = try loadAdmin1Lookup(from: admin1Path)
        print("Loaded \(admin1Lookup.count) admin1 codes")

        let admin2Path = tempDir.appendingPathComponent("admin2Codes.txt")
        print("Downloading admin2Codes.txt...")
        let admin2Curl = Process()
        admin2Curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        admin2Curl.arguments = ["-#", "-L", "-o", admin2Path.path,
                                "https://download.geonames.org/export/dump/admin2Codes.txt"]
        try admin2Curl.run()
        admin2Curl.waitUntilExit()
        guard admin2Curl.terminationStatus == 0 else {
            fatalError("Failed to download admin2Codes.txt")
        }
        let admin2Lookup = try loadAdmin2Lookup(from: admin2Path)
        print("Loaded \(admin2Lookup.count) admin2 codes")

        // 3. Download cities500.zip
        let zipPath = tempDir.appendingPathComponent("cities500.zip")
        print("Downloading cities500.zip...")
        let curlProcess = Process()
        curlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curlProcess.arguments = ["-#", "-L", "-o", zipPath.path,
                                 "https://download.geonames.org/export/dump/cities500.zip"]
        try curlProcess.run()
        curlProcess.waitUntilExit()
        guard curlProcess.terminationStatus == 0 else {
            fatalError("Failed to download cities500.zip")
        }
        let zipSize = (try fileManager.attributesOfItem(atPath: zipPath.path)[.size] as? NSNumber)?.intValue ?? 0
        print("Downloaded \(zipSize) bytes")

        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProcess.arguments = ["-o", zipPath.path, "-d", tempDir.path]
        unzipProcess.standardOutput = FileHandle.nullDevice
        try unzipProcess.run()
        unzipProcess.waitUntilExit()
        guard unzipProcess.terminationStatus == 0 else {
            fatalError("Failed to unzip cities500.zip")
        }

        let txtPath = tempDir.appendingPathComponent("cities500.txt")
        guard fileManager.fileExists(atPath: txtPath.path) else {
            fatalError("cities500.txt not found after unzipping")
        }
        print("Unzipped cities500.txt")

        // 4. Parse tab-separated data into City structs with dictionary lookups
        let txtData = try String(contentsOf: txtPath, encoding: .utf8)
        print("Parsing cities...")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        var cities: [City] = []
        cities.reserveCapacity(230_000)
        var modificationDateCache: [String: Date] = [:]
        modificationDateCache.reserveCapacity(256)

        txtData.enumerateLines { line, _ in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 19 else { return }

            let countryCode = String(fields[8])
            let admin1Code = parseOptionalField(fields[10])
            let admin2Code = parseOptionalField(fields[11])
            let admin1Name = admin1Code.flatMap { code in
                admin1Lookup[makeAdmin1LookupKey(countryCode: countryCode, admin1Code: code)]
            }
            let admin2Name = admin1Code.flatMap { a1 in
                admin2Code.flatMap { a2 in
                    admin2Lookup[makeAdmin2LookupKey(countryCode: countryCode, admin1Code: a1, admin2Code: a2)]
                }
            }
            let modificationDate: Date?
            if fields[18].isEmpty {
                modificationDate = nil
            } else {
                let dateKey = String(fields[18])
                if let cached = modificationDateCache[dateKey] {
                    modificationDate = cached
                } else {
                    let parsed = dateFormatter.date(from: dateKey)
                    if let parsed {
                        modificationDateCache[dateKey] = parsed
                    }
                    modificationDate = parsed
                }
            }

            // Split alternate names into ASCII vs non-ASCII at build time
            var altAscii: [String] = []
            var altNonAscii: [String] = []
            for alt in parseCSVField(fields[3]) {
                if alt.utf8.allSatisfy({ $0 < 0x80 }) {
                    altAscii.append(alt)
                } else {
                    altNonAscii.append(alt)
                }
            }

            let city = City(
                geonameId: Int(fields[0]) ?? 0,
                name: String(fields[1]),
                asciiName: String(fields[2]),
                alternateNames: altNonAscii,
                alternateAsciiNames: altAscii,
                latitude: Double(fields[4]) ?? 0.0,
                longitude: Double(fields[5]) ?? 0.0,
                featureClass: parseOptionalField(fields[6]),
                featureCode: parseOptionalField(fields[7]),
                countryCode: countryCode,
                cc2: parseCSVField(fields[9]),
                admin1Code: admin1Code,
                admin1Name: admin1Name,
                admin2Code: admin2Code,
                admin2Name: admin2Name,
                admin3Code: parseOptionalField(fields[12]),
                admin4Code: parseOptionalField(fields[13]),
                population: Int(fields[14]) ?? 0,
                elevation: fields[15].isEmpty ? nil : Int(fields[15]),
                dem: fields[16].isEmpty ? nil : Int(fields[16]),
                timezone: parseOptionalField(fields[17]),
                modificationDate: modificationDate
            )
            cities.append(city)
        }
        print("Parsed \(cities.count) cities")

        // 5. Sort by population descending
        cities.sort { $0.population > $1.population }
        print("Sorted \(cities.count) cities by population")

        // 6. Encode as LZ4-compressed binary
        let payload = serializeCities(cities)
        print("Uncompressed payload: \(payload.count) bytes")

        let compressed = try compressLZ4(payload)
        print("LZ4 compressed: \(compressed.count) bytes")

        // Build final file: 8-byte uncompressed size + compressed data
        var fileData = Data(capacity: 8 + compressed.count)
        var uncompressedSize = UInt64(payload.count).littleEndian
        fileData.append(Data(bytes: &uncompressedSize, count: 8))
        fileData.append(compressed)

        // 7. Write to output path
        let outputDir = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Remove existing file if present
        if fileManager.fileExists(atPath: outputPath) {
            try fileManager.removeItem(atPath: outputPath)
        }

        try fileData.write(to: URL(fileURLWithPath: outputPath))

        let fileSize = fileData.count
        print("Done! Data saved to \(outputPath) (\(fileSize / 1024 / 1024) MB)")

        // 8. Verify: print top 10 cities
        print("\n=== Top 10 cities by population ===")
        for city in cities.prefix(10) {
            printCity(city)
            print()
        }

        print("\n=== Top 10 US cities by population ===")
        for city in cities.filter({ $0.countryCode == "US" }).prefix(10) {
            printCity(city)
            print()
        }
    }

    // MARK: - Parsing Helpers

    typealias Admin1Lookup = [String: String]
    typealias Admin2Lookup = [String: String]

    static func loadAdmin1Lookup(from path: URL) throws -> Admin1Lookup {
        let text = try String(contentsOf: path, encoding: .utf8)
        var lookup: Admin1Lookup = [:]
        lookup.reserveCapacity(5000)

        text.enumerateLines { line, _ in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { return }
            lookup[String(cols[0])] = String(cols[2]) // ASCII name column
        }

        return lookup
    }

    static func loadAdmin2Lookup(from path: URL) throws -> Admin2Lookup {
        let text = try String(contentsOf: path, encoding: .utf8)
        var lookup: Admin2Lookup = [:]
        lookup.reserveCapacity(400_000)

        text.enumerateLines { line, _ in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { return }
            lookup[String(cols[0])] = String(cols[2]) // ASCII name column
        }

        return lookup
    }

    @inline(__always)
    static func makeAdmin1LookupKey(countryCode: String, admin1Code: String) -> String {
        var key = String()
        key.reserveCapacity(countryCode.count + admin1Code.count + 1)
        key.append(countryCode)
        key.append(".")
        key.append(admin1Code)
        return key
    }

    @inline(__always)
    static func makeAdmin2LookupKey(countryCode: String, admin1Code: String, admin2Code: String) -> String {
        var key = String()
        key.reserveCapacity(countryCode.count + admin1Code.count + admin2Code.count + 2)
        key.append(countryCode)
        key.append(".")
        key.append(admin1Code)
        key.append(".")
        key.append(admin2Code)
        return key
    }

    @inline(__always)
    static func parseOptionalField(_ field: Substring) -> String? {
        field.isEmpty ? nil : String(field)
    }

    @inline(__always)
    static func parseCSVField(_ field: Substring) -> [String] {
        guard !field.isEmpty else { return [] }

        var values: [String] = []
        values.reserveCapacity(4)

        for item in field.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            values.append(String(trimmed))
        }

        return values
    }

    // MARK: - Binary Serialization

    static func serializeCities(_ cities: [City]) -> Data {
        // Estimate ~200 bytes per city
        var data = Data(capacity: 12 + cities.count * 200)

        // Header: magic "WCDB" + version 2 + city count
        data.append(contentsOf: [0x57, 0x43, 0x44, 0x42]) // "WCDB"
        appendUInt32(&data, 2) // version
        appendUInt32(&data, UInt32(cities.count))

        for city in cities {
            appendInt64(&data, Int64(city.geonameId))
            appendString(&data, city.name)
            appendString(&data, city.asciiName)
            appendStringArray(&data, city.alternateNames)
            appendStringArray(&data, city.alternateAsciiNames)
            appendDouble(&data, city.latitude)
            appendDouble(&data, city.longitude)
            appendOptionalString(&data, city.featureClass)
            appendOptionalString(&data, city.featureCode)
            appendString(&data, city.countryCode)
            appendStringArray(&data, city.cc2)
            appendOptionalString(&data, city.admin1Code)
            appendOptionalString(&data, city.admin2Code)
            appendOptionalString(&data, city.admin3Code)
            appendOptionalString(&data, city.admin4Code)
            appendInt64(&data, Int64(city.population))
            appendOptionalInt(&data, city.elevation)
            appendOptionalInt(&data, city.dem)
            appendOptionalString(&data, city.timezone)
            appendOptionalDate(&data, city.modificationDate)
            appendOptionalString(&data, city.admin1Name)
            appendOptionalString(&data, city.admin2Name)
        }

        return data
    }

    static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    static func appendInt64(_ data: inout Data, _ value: Int64) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    static func appendDouble(_ data: inout Data, _ value: Double) {
        var v = value.bitPattern.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    static func appendString(_ data: inout Data, _ value: String) {
        let utf8 = Array(value.utf8)
        appendUInt32(&data, UInt32(utf8.count))
        data.append(contentsOf: utf8)
    }

    static func appendOptionalString(_ data: inout Data, _ value: String?) {
        if let value = value {
            data.append(1)
            appendString(&data, value)
        } else {
            data.append(0)
        }
    }

    static func appendStringArray(_ data: inout Data, _ value: [String]) {
        appendUInt32(&data, UInt32(value.count))
        for s in value {
            appendString(&data, s)
        }
    }

    static func appendOptionalInt(_ data: inout Data, _ value: Int?) {
        if let value = value {
            data.append(1)
            appendInt64(&data, Int64(value))
        } else {
            data.append(0)
        }
    }

    static func appendOptionalDate(_ data: inout Data, _ value: Date?) {
        if let value = value {
            data.append(1)
            appendDouble(&data, value.timeIntervalSinceReferenceDate)
        } else {
            data.append(0)
        }
    }

    // MARK: - LZ4 Compression

    static func compressLZ4(_ input: Data) throws -> Data {
        let srcSize = input.count
        let dstCapacity = srcSize + srcSize / 255 + 16 // worst-case LZ4 expansion
        var dst = Data(count: dstCapacity)

        let compressedSize = input.withUnsafeBytes { srcPtr in
            dst.withUnsafeMutableBytes { dstPtr in
                compression_encode_buffer(
                    dstPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    dstCapacity,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    srcSize,
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }

        guard compressedSize > 0 else {
            fatalError("LZ4 compression failed")
        }

        dst.count = compressedSize
        return dst
    }
}
