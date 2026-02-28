import Foundation

/// Protocol for user-defined city types. Conform to this to select only the fields you need.
public protocol CityRepresentable: Sendable {
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
    init(reader: inout BinaryReader) {
        self.buffer = reader.buffer

        // Fixed layout matching BuildDB serialization order
        self.geonameId = Int(reader.readInt64())
        self.nameRange = reader.readStringRange()
        self.asciiNameRange = reader.readStringRange()
        self.alternateNamesRanges = reader.readStringArrayRanges()
        self.alternateAsciiNamesRanges = reader.readStringArrayRanges()
        self.latitude = reader.readDouble()
        self.longitude = reader.readDouble()
        self.featureClassRange = reader.readOptionalStringRange()
        self.featureCodeRange = reader.readOptionalStringRange()
        self.countryCodeRange = reader.readStringRange()
        self.cc2Ranges = reader.readStringArrayRanges()
        self.admin1CodeRange = reader.readOptionalStringRange()
        self.admin2CodeRange = reader.readOptionalStringRange()
        self.admin3CodeRange = reader.readOptionalStringRange()
        self.admin4CodeRange = reader.readOptionalStringRange()
        self.population = Int(reader.readInt64())
        self.elevation = reader.readOptionalInt()
        self.dem = reader.readOptionalInt()
        self.timezoneRange = reader.readOptionalStringRange()
        self.modificationDate = reader.readOptionalDate()
        self.admin1NameRange = reader.readOptionalStringRange()
        self.admin2NameRange = reader.readOptionalStringRange()
    }
}

// MARK: - BinaryReader

struct BinaryReader {
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

    /// Returns (offset, length) for a length-prefixed string without allocating.
    mutating func readStringRange() -> (Int, Int) {
        let length = Int(readUInt32())
        let start = offset
        offset += length
        return (start, length)
    }

    /// Reads a string (allocates). Used only where needed.
    mutating func readString() -> String {
        let length = Int(readUInt32())
        let str = String(unsafeUninitializedCapacity: length) { buf in
            buf.baseAddress!.update(
                from: buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                count: length
            )
            return length
        }
        offset += length
        return str
    }

    mutating func readOptionalStringRange() -> (Int, Int)? {
        let flag = buffer.load(fromByteOffset: offset, as: UInt8.self)
        offset += 1
        return flag == 1 ? readStringRange() : nil
    }

    mutating func readStringArrayRanges() -> [(Int, Int)] {
        let count = Int(readUInt32())
        var result: [(Int, Int)] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(readStringRange())
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
