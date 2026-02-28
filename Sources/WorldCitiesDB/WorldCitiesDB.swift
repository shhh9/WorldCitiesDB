import Compression
import Foundation

/// Provides read-only access to the bundled world cities database.
///
/// Generic over the city type — users define their own struct with only the fields they need.
/// Cities are pre-sorted by population (descending) from the binary.
public final class WorldCitiesDB<C: CityRepresentable>: Sendable {

    /// All cities sorted by population (descending).
    public let cities: [C]

    /// Total number of cities.
    public var count: Int { cities.count }

    /// Creates a new instance using the bundled cities data.
    public convenience init() throws {
        guard let url = Bundle.module.url(forResource: "cities", withExtension: "lz4", subdirectory: "Resources") else {
            fatalError("cities.lz4 not found in bundle. Run BuildDB to generate it.")
        }
        try self.init(data: Data(contentsOf: url))
    }

    /// Creates an instance from pre-loaded LZ4-compressed binary data.
    public init(data: Data) throws {
        self.cities = try Self.decodeBinary(from: data)
    }

    // MARK: - Binary Decoding

    private static func decodeBinary(from fileData: Data) throws -> [C] {
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
            guard magic == 0x4244_4357 else { // "WCDB"
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Invalid magic: \(String(magic, radix: 16))"
                ))
            }
            let version = reader.readUInt32()
            guard version == 2 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Unsupported version: \(version)"
                ))
            }
            let cityCount = Int(reader.readUInt32())

            var cities: [C] = []
            cities.reserveCapacity(cityCount)

            for _ in 0..<cityCount {
                let fields = CityFields(reader: &reader)
                cities.append(C(from: fields))
            }

            return cities
        }
    }
}
