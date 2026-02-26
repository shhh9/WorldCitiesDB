import Compression
import Foundation
import WorldCitiesDB

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

        // 1. Download cities500.zip
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

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
        let zipData = try Data(contentsOf: zipPath)
        print("Downloaded \(zipData.count) bytes")

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

        // 3. Parse tab-separated data into City structs
        let txtData = try String(contentsOf: txtPath, encoding: .utf8)
        let lines = txtData.components(separatedBy: "\n").filter { !$0.isEmpty }
        print("Parsing \(lines.count) cities...")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        var cities: [City] = []
        cities.reserveCapacity(lines.count)

        for line in lines {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 19 else { continue }

            // Split alternateNames by comma, trim, filter empties
            let altNames: [String] = fields[3].isEmpty ? [] :
                fields[3].components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

            // Split cc2 by comma, trim, filter empties
            let cc2: [String] = fields[9].isEmpty ? [] :
                fields[9].components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

            // Parse modification date
            let modDate: Date? = fields[18].isEmpty ? nil : dateFormatter.date(from: fields[18])

            let city = City(
                geonameId: Int(fields[0]) ?? 0,
                name: fields[1],
                asciiName: fields[2],
                alternateNames: altNames,
                latitude: Double(fields[4]) ?? 0.0,
                longitude: Double(fields[5]) ?? 0.0,
                featureClass: fields[6].isEmpty ? nil : fields[6],
                featureCode: fields[7].isEmpty ? nil : fields[7],
                countryCode: fields[8],
                cc2: cc2,
                admin1Code: fields[10].isEmpty ? nil : fields[10],
                admin2Code: fields[11].isEmpty ? nil : fields[11],
                admin3Code: fields[12].isEmpty ? nil : fields[12],
                admin4Code: fields[13].isEmpty ? nil : fields[13],
                population: Int(fields[14]) ?? 0,
                elevation: fields[15].isEmpty ? nil : Int(fields[15]),
                dem: fields[16].isEmpty ? nil : Int(fields[16]),
                timezone: fields[17].isEmpty ? nil : fields[17],
                modificationDate: modDate
            )
            cities.append(city)
        }

        // 4. Sort by population descending
        cities.sort { $0.population > $1.population }
        print("Sorted \(cities.count) cities by population")

        // 5. Encode as LZ4-compressed binary
        let payload = serializeCities(cities)
        print("Uncompressed payload: \(payload.count) bytes")

        let compressed = try compressLZ4(payload)
        print("LZ4 compressed: \(compressed.count) bytes")

        // Build final file: 8-byte uncompressed size + compressed data
        var fileData = Data(capacity: 8 + compressed.count)
        var uncompressedSize = UInt64(payload.count).littleEndian
        fileData.append(Data(bytes: &uncompressedSize, count: 8))
        fileData.append(compressed)

        // 6. Write to output path
        let outputDir = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Remove existing file if present
        if fileManager.fileExists(atPath: outputPath) {
            try fileManager.removeItem(atPath: outputPath)
        }

        try fileData.write(to: URL(fileURLWithPath: outputPath))

        let fileSize = fileData.count
        print("Done! Data saved to \(outputPath) (\(fileSize / 1024 / 1024) MB)")
    }

    // MARK: - Binary Serialization

    static func serializeCities(_ cities: [City]) -> Data {
        // Estimate ~200 bytes per city
        var data = Data(capacity: 12 + cities.count * 200)

        // Header: magic "WCDB" + version 1 + city count
        data.append(contentsOf: [0x57, 0x43, 0x44, 0x42]) // "WCDB"
        appendUInt32(&data, 1) // version
        appendUInt32(&data, UInt32(cities.count))

        for city in cities {
            appendInt64(&data, Int64(city.geonameId))
            appendString(&data, city.name)
            appendString(&data, city.asciiName)
            appendStringArray(&data, city.alternateNames)
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
