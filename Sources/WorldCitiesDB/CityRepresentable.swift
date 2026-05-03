import Foundation

/// Protocol for user-defined city types. Conform to this to select only the fields you need.
public protocol CityRepresentable {
    init(from fields: borrowing CityFields)
}

/// Lazy field accessor for a single city record in the binary database.
///
/// Pre-scans the binary record to find field boundaries without allocating strings.
/// String fields are only materialized when their accessor is called.
/// `~Copyable` prevents escaping the buffer scope.
public struct CityFields: ~Copyable {
    // Numeric fields — always parsed, zero cost
    public let geonameId: Int
    public let latitude: Double
    public let longitude: Double
    public let population: Int
    public let elevation: Int?
    public let dem: Int?
    public let modificationDate: Date?

    // String field boundaries (offset, length) into the buffer
    private let buffer: UnsafeRawBufferPointer
    private let nameRange: (Int, Int)
    private let asciiNameRange: (Int, Int)
    private let alternateNamesRanges: [(Int, Int)]      // non-ASCII
    private let alternateAsciiNamesRanges: [(Int, Int)]  // ASCII
    private let featureClassRange: (Int, Int)?
    private let featureCodeRange: (Int, Int)?
    private let countryCodeRange: (Int, Int)
    private let cc2Ranges: [(Int, Int)]
    private let admin1CodeRange: (Int, Int)?
    private let admin2CodeRange: (Int, Int)?
    private let admin3CodeRange: (Int, Int)?
    private let admin4CodeRange: (Int, Int)?
    private let timezoneRange: (Int, Int)?
    private let admin1NameRange: (Int, Int)?
    private let admin2NameRange: (Int, Int)?

    // MARK: - String Accessors

    public func name() -> String {
        makeString(nameRange)
    }

    public func asciiName() -> String {
        makeString(asciiNameRange)
    }

    /// Non-ASCII alternate names.
    public func alternateNames() -> [String] {
        alternateNamesRanges.map { makeString($0) }
    }

    /// ASCII-only alternate names.
    public func alternateAsciiNames() -> [String] {
        alternateAsciiNamesRanges.map { makeString($0) }
    }

    public func featureClass() -> String? {
        featureClassRange.map { makeString($0) }
    }

    public func featureCode() -> String? {
        featureCodeRange.map { makeString($0) }
    }

    public func countryCode() -> String {
        makeString(countryCodeRange)
    }

    public func cc2() -> [String] {
        cc2Ranges.map { makeString($0) }
    }

    public func admin1Code() -> String? {
        admin1CodeRange.map { makeString($0) }
    }

    public func admin1Name() -> String? {
        admin1NameRange.map { makeString($0) }
    }

    public func admin2Code() -> String? {
        admin2CodeRange.map { makeString($0) }
    }

    public func admin2Name() -> String? {
        admin2NameRange.map { makeString($0) }
    }

    public func admin3Code() -> String? {
        admin3CodeRange.map { makeString($0) }
    }

    public func admin4Code() -> String? {
        admin4CodeRange.map { makeString($0) }
    }

    public func timezone() -> String? {
        timezoneRange.map { makeString($0) }
    }

    // MARK: - Internal

    private func makeString(_ range: (Int, Int)) -> String {
        let (offset, length) = range
        guard length > 0 else { return "" }
        return String(unsafeUninitializedCapacity: length) { buf in
            buf.baseAddress!.update(
                from: buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                count: length
            )
            return length
        }
    }

    /// Reads a city record from the binary buffer at the given reader offset.
    /// Returns the CityFields and advances the reader past this record.
    init(reader: inout BinaryReader) throws {
        // Fixed layout matching BuildDB serialization order
        let buffer = reader.buffer
        let geonameId = Int(try reader.readInt64())
        let nameRange = try reader.readStringRange()
        let asciiNameRange = try reader.readStringRange()
        let alternateNamesRanges = try reader.readStringArrayRanges()
        let alternateAsciiNamesRanges = try reader.readStringArrayRanges()
        let latitude = try reader.readDouble()
        let longitude = try reader.readDouble()
        let featureClassRange = try reader.readOptionalStringRange()
        let featureCodeRange = try reader.readOptionalStringRange()
        let countryCodeRange = try reader.readStringRange()
        let cc2Ranges = try reader.readStringArrayRanges()
        let admin1CodeRange = try reader.readOptionalStringRange()
        let admin2CodeRange = try reader.readOptionalStringRange()
        let admin3CodeRange = try reader.readOptionalStringRange()
        let admin4CodeRange = try reader.readOptionalStringRange()
        let population = Int(try reader.readInt64())
        let elevation = try reader.readOptionalInt()
        let dem = try reader.readOptionalInt()
        let timezoneRange = try reader.readOptionalStringRange()
        let modificationDate = try reader.readOptionalDate()
        let admin1NameRange = try reader.readOptionalStringRange()
        let admin2NameRange = try reader.readOptionalStringRange()

        guard reader.isAtEnd else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "City record has trailing bytes"
            ))
        }

        self.buffer = buffer
        self.geonameId = geonameId
        self.nameRange = nameRange
        self.asciiNameRange = asciiNameRange
        self.alternateNamesRanges = alternateNamesRanges
        self.alternateAsciiNamesRanges = alternateAsciiNamesRanges
        self.latitude = latitude
        self.longitude = longitude
        self.featureClassRange = featureClassRange
        self.featureCodeRange = featureCodeRange
        self.countryCodeRange = countryCodeRange
        self.cc2Ranges = cc2Ranges
        self.admin1CodeRange = admin1CodeRange
        self.admin2CodeRange = admin2CodeRange
        self.admin3CodeRange = admin3CodeRange
        self.admin4CodeRange = admin4CodeRange
        self.population = population
        self.elevation = elevation
        self.dem = dem
        self.timezoneRange = timezoneRange
        self.modificationDate = modificationDate
        self.admin1NameRange = admin1NameRange
        self.admin2NameRange = admin2NameRange
    }
}

// MARK: - BinaryReader

struct BinaryReader {
    let buffer: UnsafeRawBufferPointer
    var offset: Int = 0

    var isAtEnd: Bool { offset == buffer.count }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < buffer.count else {
            throw corrupted("Unexpected end of data while reading UInt8")
        }
        let value = buffer.load(fromByteOffset: offset, as: UInt8.self)
        offset += 1
        return value
    }

    mutating func readUInt32() throws -> UInt32 {
        try requireAvailable(4, reading: "UInt32")
        let value = buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        offset += 4
        return value
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readInt64() throws -> Int64 {
        try requireAvailable(8, reading: "Int64")
        let value = buffer.loadUnaligned(fromByteOffset: offset, as: Int64.self).littleEndian
        offset += 8
        return value
    }

    mutating func readDouble() throws -> Double {
        try requireAvailable(8, reading: "Double")
        let bits = buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
        offset += 8
        return Double(bitPattern: bits)
    }

    mutating func readData(count: Int) throws -> Data {
        let range = try readRange(count: count, reading: "byte range")
        return Data(buffer.bindMemory(to: UInt8.self)[range])
    }

    mutating func readBuffer(count: Int) throws -> UnsafeRawBufferPointer {
        let range = try readRange(count: count, reading: "byte range")
        return UnsafeRawBufferPointer(rebasing: buffer[range])
    }

    /// Returns (offset, length) for a length-prefixed string without allocating.
    mutating func readStringRange() throws -> (Int, Int) {
        let length = Int(try readUInt32())
        let range = try readRange(count: length, reading: "string")
        let start = range.lowerBound
        return (start, length)
    }

    /// Reads a string (allocates). Used only where needed.
    mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        let range = try readRange(count: length, reading: "string")
        let str = String(unsafeUninitializedCapacity: length) { buf in
            buf.baseAddress!.update(
                from: buffer.baseAddress!.advanced(by: range.lowerBound).assumingMemoryBound(to: UInt8.self),
                count: length
            )
            return length
        }
        return str
    }

    mutating func readOptionalStringRange() throws -> (Int, Int)? {
        let length = try readUInt32()
        guard length != UInt32.max else { return nil }
        let range = try readRange(count: Int(length), reading: "optional string")
        return (range.lowerBound, Int(length))
    }

    mutating func readStringArrayRanges() throws -> [(Int, Int)] {
        let count = Int(try readUInt32())
        var result: [(Int, Int)] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try readStringRange())
        }
        return result
    }

    mutating func readOptionalInt() throws -> Int? {
        let value = try readInt64()
        return value == Int64.min ? nil : Int(value)
    }

    mutating func readOptionalDate() throws -> Date? {
        let days = try readInt32()
        guard days != Int32.min else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(days) * 86_400)
    }

    private mutating func readRange(count: Int, reading label: String) throws -> Range<Int> {
        try requireAvailable(count, reading: label)
        let start = offset
        offset += count
        return start..<offset
    }

    private func requireAvailable(_ byteCount: Int, reading label: String) throws {
        guard byteCount >= 0, offset <= buffer.count, buffer.count - offset >= byteCount else {
            throw corrupted("Unexpected end of data while reading \(label)")
        }
    }

    private func corrupted(_ description: String) -> Error {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
    }
}
