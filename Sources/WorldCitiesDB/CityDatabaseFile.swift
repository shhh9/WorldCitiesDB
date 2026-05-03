import Compression
import Foundation

public struct CityDatabaseMetadata: Codable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let sourceName: String
    public let sourceURLs: [String]
    public let cityCount: Int
    public let sortOrder: String
    public let cityDataFingerprint: String
    public let searchDataFingerprint: String
    public let searchSchemaID: String
    public let foldOptionsVersion: Int
    public let includesAdmin1Names: Bool
    public let includesAdmin2Names: Bool

    public init(
        schemaVersion: Int,
        generatedAt: String,
        sourceName: String,
        sourceURLs: [String],
        cityCount: Int,
        sortOrder: String,
        cityDataFingerprint: String,
        searchDataFingerprint: String,
        searchSchemaID: String,
        foldOptionsVersion: Int,
        includesAdmin1Names: Bool,
        includesAdmin2Names: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.sourceName = sourceName
        self.sourceURLs = sourceURLs
        self.cityCount = cityCount
        self.sortOrder = sortOrder
        self.cityDataFingerprint = cityDataFingerprint
        self.searchDataFingerprint = searchDataFingerprint
        self.searchSchemaID = searchSchemaID
        self.foldOptionsVersion = foldOptionsVersion
        self.includesAdmin1Names = includesAdmin1Names
        self.includesAdmin2Names = includesAdmin2Names
    }

    public func with(
        cityCount: Int,
        cityDataFingerprint: String,
        searchDataFingerprint: String
    ) -> CityDatabaseMetadata {
        CityDatabaseMetadata(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            sourceName: sourceName,
            sourceURLs: sourceURLs,
            cityCount: cityCount,
            sortOrder: sortOrder,
            cityDataFingerprint: cityDataFingerprint,
            searchDataFingerprint: searchDataFingerprint,
            searchSchemaID: searchSchemaID,
            foldOptionsVersion: foldOptionsVersion,
            includesAdmin1Names: includesAdmin1Names,
            includesAdmin2Names: includesAdmin2Names
        )
    }
}

package struct EncodedCityDatabase {
    package let data: Data
    package let metadata: CityDatabaseMetadata
    package let searchArtifacts: SearchArtifacts
}

package struct DecodedCityDatabase<C: CityRepresentable> {
    package let cities: [C]
    package let metadata: CityDatabaseMetadata
    package let searchArtifacts: SearchArtifacts
}

package enum CityDatabaseFile {
    package static let currentSchemaVersion = 3
    package static let defaultSearchSchemaID = "WorldCitiesDB.CitySearch.v1"
    package static let currentFoldOptionsVersion = 1

    private static let fileVersion: UInt32 = 3
    private static let cityPayloadVersion: UInt32 = 2
    private static let magic = BinaryDataWriter.fourCC("WCDB")

    package static func serializedData(
        cities: [City],
        metadata: CityDatabaseMetadata,
        searchArtifacts: SearchArtifacts
    ) throws -> EncodedCityDatabase {
        try validate(searchArtifacts: searchArtifacts, cityCount: cities.count)

        let cityPayload = serializeCityPayload(cities)
        let searchPayload = searchArtifacts.serializedData()
        let cityChecksum = DatabaseCRC32.checksum(cityPayload)
        let searchChecksum = DatabaseCRC32.checksum(searchPayload)
        let resolvedMetadata = metadata.with(
            cityCount: cities.count,
            cityDataFingerprint: DatabaseCRC32.hex(cityChecksum),
            searchDataFingerprint: DatabaseCRC32.hex(searchChecksum)
        )
        let metadataData = try metadataJSONData(resolvedMetadata)
        let compressedCityPayload = try DatabaseLZ4.compress(cityPayload)
        let compressedSearchPayload = try DatabaseLZ4.compress(searchPayload)

        var writer = BinaryDataWriter()
        writer.appendUInt32(magic)
        writer.appendUInt32(fileVersion)
        writer.appendUInt32(UInt32(metadataData.count))
        writer.appendUInt32(UInt32(cityPayload.count))
        writer.appendUInt32(UInt32(compressedCityPayload.count))
        writer.appendUInt32(cityChecksum)
        writer.appendUInt32(UInt32(searchPayload.count))
        writer.appendUInt32(UInt32(compressedSearchPayload.count))
        writer.appendUInt32(searchChecksum)
        writer.appendBytes(metadataData)
        writer.appendBytes(compressedCityPayload)
        writer.appendBytes(compressedSearchPayload)
        return EncodedCityDatabase(data: writer.data, metadata: resolvedMetadata, searchArtifacts: searchArtifacts)
    }

    package static func decode<C: CityRepresentable>(from data: Data) throws -> DecodedCityDatabase<C> {
        let decoded: (CityDatabaseMetadata, Data, Data) = try data.withUnsafeBytes { raw in
            var reader = BinaryReader(buffer: raw)
            let actualMagic = try reader.readUInt32()
            guard actualMagic == magic else {
                throw corrupted("Invalid city database magic")
            }

            let version = try reader.readUInt32()
            guard version == fileVersion else {
                throw corrupted("Unsupported city database version: \(version)")
            }

            let metadataByteCount = Int(try reader.readUInt32())
            let cityUncompressedByteCount = Int(try reader.readUInt32())
            let cityCompressedByteCount = Int(try reader.readUInt32())
            let cityPayloadChecksum = try reader.readUInt32()
            let searchUncompressedByteCount = Int(try reader.readUInt32())
            let searchCompressedByteCount = Int(try reader.readUInt32())
            let searchPayloadChecksum = try reader.readUInt32()

            let metadataData = try reader.readData(count: metadataByteCount)
            let compressedCityPayload = try reader.readBuffer(count: cityCompressedByteCount)
            let cityPayload = try DatabaseLZ4.decompress(
                compressedCityPayload,
                uncompressedByteCount: cityUncompressedByteCount
            )
            let compressedSearchPayload = try reader.readBuffer(count: searchCompressedByteCount)
            guard reader.isAtEnd else {
                throw corrupted("City database has trailing bytes")
            }

            let metadata = try JSONDecoder().decode(CityDatabaseMetadata.self, from: metadataData)
            guard metadata.schemaVersion == currentSchemaVersion else {
                throw corrupted("Unsupported city database schema version: \(metadata.schemaVersion)")
            }
            let actualCityChecksum = DatabaseCRC32.checksum(cityPayload)
            guard actualCityChecksum == cityPayloadChecksum else {
                throw corrupted("City database payload checksum mismatch")
            }
            let actualCityFingerprint = DatabaseCRC32.hex(actualCityChecksum)
            guard metadata.cityDataFingerprint == actualCityFingerprint else {
                throw corrupted("City database metadata fingerprint mismatch")
            }

            let searchPayload = try DatabaseLZ4.decompress(
                compressedSearchPayload,
                uncompressedByteCount: searchUncompressedByteCount
            )
            let actualSearchChecksum = DatabaseCRC32.checksum(searchPayload)
            guard actualSearchChecksum == searchPayloadChecksum else {
                throw corrupted("Search artifact payload checksum mismatch")
            }
            let actualSearchFingerprint = DatabaseCRC32.hex(actualSearchChecksum)
            guard metadata.searchDataFingerprint == actualSearchFingerprint else {
                throw corrupted("Search artifact metadata fingerprint mismatch")
            }
            guard metadata.searchSchemaID == defaultSearchSchemaID,
                  metadata.foldOptionsVersion == currentFoldOptionsVersion else {
                throw corrupted("Unsupported bundled search artifact schema")
            }
            return (metadata, cityPayload, searchPayload)
        }

        let cities: [C] = try decoded.1.withUnsafeBytes { raw in
            var reader = BinaryReader(buffer: raw)
            let payloadVersion = try reader.readUInt32()
            guard payloadVersion == cityPayloadVersion else {
                throw corrupted("Unsupported city payload version: \(payloadVersion)")
            }

            let cityCount = Int(try reader.readUInt32())
            guard cityCount >= 0 else {
                throw corrupted("Invalid city count")
            }

            var cities: [C] = []
            cities.reserveCapacity(cityCount)
            for _ in 0..<cityCount {
                let recordByteCount = Int(try reader.readUInt32())
                let recordBuffer = try reader.readBuffer(count: recordByteCount)
                var recordReader = BinaryReader(buffer: recordBuffer)
                let fields = try CityFields(reader: &recordReader)
                cities.append(C(from: fields))
            }

            guard reader.isAtEnd else {
                throw corrupted("City payload has trailing bytes")
            }
            guard cities.count == decoded.0.cityCount else {
                throw corrupted("City count does not match metadata")
            }
            return cities
        }

        let searchArtifacts = try SearchArtifacts(serializedData: decoded.2)
        try validate(searchArtifacts: searchArtifacts, cityCount: decoded.0.cityCount)

        return DecodedCityDatabase(cities: cities, metadata: decoded.0, searchArtifacts: searchArtifacts)
    }

    private static func serializeCityPayload(_ cities: [City]) -> Data {
        var writer = BinaryDataWriter(capacity: 8 + cities.count * 220)
        writer.appendUInt32(cityPayloadVersion)
        writer.appendUInt32(UInt32(cities.count))

        for city in cities {
            var record = BinaryDataWriter(capacity: 220)
            record.appendInt64(Int64(city.geonameId))
            record.appendString(city.name)
            record.appendString(city.asciiName)
            record.appendStringArray(city.alternateNames)
            record.appendStringArray(city.alternateAsciiNames)
            record.appendDouble(city.latitude)
            record.appendDouble(city.longitude)
            record.appendOptionalString(city.featureClass)
            record.appendOptionalString(city.featureCode)
            record.appendString(city.countryCode)
            record.appendStringArray(city.cc2)
            record.appendOptionalString(city.admin1Code)
            record.appendOptionalString(city.admin2Code)
            record.appendOptionalString(city.admin3Code)
            record.appendOptionalString(city.admin4Code)
            record.appendInt64(Int64(city.population))
            record.appendOptionalInt(city.elevation)
            record.appendOptionalInt(city.dem)
            record.appendOptionalString(city.timezone)
            record.appendOptionalDate(city.modificationDate)
            record.appendOptionalString(city.admin1Name)
            record.appendOptionalString(city.admin2Name)

            writer.appendUInt32(UInt32(record.data.count))
            writer.appendBytes(record.data)
        }

        return writer.data
    }

    static func metadataJSONData(_ metadata: CityDatabaseMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(metadata)
    }

    private static func corrupted(_ description: String) -> Error {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
    }

    private static func validate(searchArtifacts: SearchArtifacts, cityCount: Int) throws {
        guard searchArtifacts.searchIndex.cityCount == cityCount else {
            throw corrupted("Search index city count does not match metadata")
        }
        guard searchArtifacts.packedSearchFields.cityCount == cityCount else {
            throw corrupted("Packed search fields city count does not match metadata")
        }
    }
}

struct BinaryDataWriter {
    private(set) var data: Data

    init(capacity: Int = 0) {
        self.data = Data(capacity: capacity)
    }

    mutating func appendBytes(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    mutating func appendInt64(_ value: Int64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendDouble(_ value: Double) {
        var littleEndian = value.bitPattern.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendString(_ value: String) {
        let utf8 = Array(value.utf8)
        appendUInt32(UInt32(utf8.count))
        data.append(contentsOf: utf8)
    }

    mutating func appendOptionalString(_ value: String?) {
        guard let value else {
            appendUInt32(UInt32.max)
            return
        }
        appendString(value)
    }

    mutating func appendStringArray(_ value: [String]) {
        appendUInt32(UInt32(value.count))
        for item in value {
            appendString(item)
        }
    }

    mutating func appendOptionalInt(_ value: Int?) {
        appendInt64(value.map(Int64.init) ?? Int64.min)
    }

    mutating func appendOptionalDate(_ value: Date?) {
        guard let value else {
            appendInt32(Int32.min)
            return
        }
        let days = Int32((value.timeIntervalSince1970 / 86_400).rounded(.towardZero))
        appendInt32(days)
    }

    static func fourCC(_ text: String) -> UInt32 {
        let bytes = Array(text.utf8)
        precondition(bytes.count == 4, "fourCC requires exactly 4 ASCII characters")
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }
}

enum DatabaseLZ4 {
    static func compress(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }
        let srcSize = input.count
        let dstCapacity = srcSize + srcSize / 255 + 16
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
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "LZ4 compression failed"))
        }
        dst.count = compressedSize
        return dst
    }

    static func decompress(_ input: UnsafeRawBufferPointer, uncompressedByteCount: Int) throws -> Data {
        guard uncompressedByteCount >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid LZ4 output size"))
        }
        guard uncompressedByteCount > 0 else { return Data() }
        guard !input.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Compressed payload is empty"))
        }

        let bytes = input.bindMemory(to: UInt8.self)
        var decompressed = Data(count: uncompressedByteCount)
        let decodedSize = decompressed.withUnsafeMutableBytes { dstPtr in
            compression_decode_buffer(
                dstPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                uncompressedByteCount,
                bytes.baseAddress!,
                bytes.count,
                nil,
                COMPRESSION_LZ4
            )
        }

        guard decodedSize == uncompressedByteCount else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "LZ4 decompression failed: expected \(uncompressedByteCount), got \(decodedSize)"
            ))
        }
        return decompressed
    }
}

enum DatabaseCRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var value = UInt32(i)
            for _ in 0..<8 {
                if value & 1 == 1 {
                    value = (value >> 1) ^ 0xEDB8_8320
                } else {
                    value >>= 1
                }
            }
            table[i] = value
        }
        return table
    }()

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { checksum($0) }
    }

    static func checksum(_ buffer: UnsafeRawBufferPointer) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        let bytes = buffer.bindMemory(to: UInt8.self)
        for byte in bytes {
            let tableIndex = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[tableIndex]
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func hex(_ checksum: UInt32) -> String {
        String(format: "%08x", checksum)
    }
}
