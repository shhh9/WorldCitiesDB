import Foundation

/// Build/load container for search structures.
/// Owns all serialization/deserialization for `CasefoldingCache` and `SearchIndex`.
public struct SearchArtifacts {
    public let casefoldingCache: CasefoldingCache
    public let searchIndex: SearchIndex
    public let packedSearchFields: PackedSearchFields

    public init(
        casefoldingCache: CasefoldingCache,
        searchIndex: SearchIndex,
        packedSearchFields: PackedSearchFields
    ) {
        self.casefoldingCache = casefoldingCache
        self.searchIndex = searchIndex
        self.packedSearchFields = packedSearchFields
    }

    public init<C: SearchableCity>(cities: [C]) {
        let casefoldingCache = CasefoldingCache.build(cities: cities)
        let searchIndex = SearchIndex.build(cities: cities, casefoldingCache: casefoldingCache)
        let packedSearchFields = PackedSearchFields.build(cities)
        self.init(
            casefoldingCache: casefoldingCache,
            searchIndex: searchIndex,
            packedSearchFields: packedSearchFields
        )
    }

    public func serializedData() -> Data {
        let casefoldData = Self.serializeCasefoldingCache(casefoldingCache)
        let indexData = Self.serializeSearchIndex(searchIndex)
        let packedFieldData = Self.serializePackedSearchFields(packedSearchFields)

        var data = Data()
        data.reserveCapacity(4 + 4 + 4 + casefoldData.count + 4 + indexData.count + 4 + packedFieldData.count)
        data.append(contentsOf: [0x53, 0x41, 0x52, 0x54]) // "SART"
        Self.appendUInt32(&data, 1) // format version
        Self.appendUInt32(&data, UInt32(casefoldData.count))
        data.append(casefoldData)
        Self.appendUInt32(&data, UInt32(indexData.count))
        data.append(indexData)
        Self.appendUInt32(&data, UInt32(packedFieldData.count))
        data.append(packedFieldData)
        return data
    }

    public init(serializedData data: Data) throws {
        let decoded: (Data, Data, Data) = try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var pos = 0

            func corrupted(_ description: String) -> Error {
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
            }

            func readByte() throws -> UInt8 {
                guard pos < bytes.count else { throw corrupted("SearchArtifacts decode: truncated byte") }
                let value = bytes[pos]
                pos &+= 1
                return value
            }

            func readUInt32() throws -> UInt32 {
                guard pos &+ 4 <= bytes.count else { throw corrupted("SearchArtifacts decode: truncated UInt32") }
                let value = UInt32(bytes[pos])
                    | (UInt32(bytes[pos &+ 1]) << 8)
                    | (UInt32(bytes[pos &+ 2]) << 16)
                    | (UInt32(bytes[pos &+ 3]) << 24)
                pos &+= 4
                return value
            }

            let m0 = try readByte()
            let m1 = try readByte()
            let m2 = try readByte()
            let m3 = try readByte()
            guard m0 == 0x53, m1 == 0x41, m2 == 0x52, m3 == 0x54 else {
                throw corrupted("SearchArtifacts decode: invalid magic")
            }

            let version = try readUInt32()
            guard version == 1 else {
                throw corrupted("SearchArtifacts decode: unsupported version \(version)")
            }

            let casefoldByteCount = Int(try readUInt32())
            guard casefoldByteCount >= 0, pos &+ casefoldByteCount <= bytes.count else {
                throw corrupted("SearchArtifacts decode: invalid casefold cache length")
            }
            let casefoldRange = pos..<(pos &+ casefoldByteCount)
            pos &+= casefoldByteCount

            let indexByteCount = Int(try readUInt32())
            guard indexByteCount >= 0, pos &+ indexByteCount <= bytes.count else {
                throw corrupted("SearchArtifacts decode: invalid search index length")
            }
            let indexRange = pos..<(pos &+ indexByteCount)
            pos &+= indexByteCount

            let packedFieldByteCount = Int(try readUInt32())
            guard packedFieldByteCount >= 0, pos &+ packedFieldByteCount <= bytes.count else {
                throw corrupted("SearchArtifacts decode: invalid packed field table length")
            }
            let packedFieldRange = pos..<(pos &+ packedFieldByteCount)
            pos &+= packedFieldByteCount

            guard pos == bytes.count else {
                throw corrupted("SearchArtifacts decode: unexpected trailing data")
            }

            return (Data(bytes[casefoldRange]), Data(bytes[indexRange]), Data(bytes[packedFieldRange]))
        }

        self.casefoldingCache = try Self.deserializeCasefoldingCache(decoded.0)
        self.searchIndex = try Self.deserializeSearchIndex(decoded.1)
        self.packedSearchFields = try Self.deserializePackedSearchFields(decoded.2)
    }

    // MARK: - Casefold Cache Serialization

    private static func serializeCasefoldingCache(_ cache: CasefoldingCache) -> Data {
        var data = Data()
        data.reserveCapacity(4 + 4 + 4 + 4 + 4 + 4 + (cache.rawTable.count * 8) + (cache.displacements.count * 4))

        data.append(contentsOf: [0x46, 0x49, 0x44, 0x58]) // "FIDX"
        appendUInt32(&data, 1) // format version
        appendUInt32(&data, UInt32(cache.rawTable.count))
        appendUInt32(&data, UInt32(cache.displacements.count))
        appendUInt32(&data, cache.seed1)
        appendUInt32(&data, cache.seed2)

        for raw in cache.rawTable {
            appendUInt64(&data, raw)
        }
        for displacement in cache.displacements {
            appendUInt32(&data, UInt32(bitPattern: displacement))
        }

        return data
    }

    private static func deserializeCasefoldingCache(_ data: Data) throws -> CasefoldingCache {
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var pos = 0

            func corrupted(_ description: String) -> Error {
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
            }

            func readByte() throws -> UInt8 {
                guard pos < bytes.count else { throw corrupted("CasefoldingCache decode: truncated byte") }
                let value = bytes[pos]
                pos &+= 1
                return value
            }

            func readUInt32() throws -> UInt32 {
                guard pos &+ 4 <= bytes.count else { throw corrupted("CasefoldingCache decode: truncated UInt32") }
                let value = UInt32(bytes[pos])
                    | (UInt32(bytes[pos &+ 1]) << 8)
                    | (UInt32(bytes[pos &+ 2]) << 16)
                    | (UInt32(bytes[pos &+ 3]) << 24)
                pos &+= 4
                return value
            }

            func readUInt64() throws -> UInt64 {
                guard pos &+ 8 <= bytes.count else { throw corrupted("CasefoldingCache decode: truncated UInt64") }
                var value: UInt64 = 0
                value |= UInt64(bytes[pos])
                value |= UInt64(bytes[pos &+ 1]) << 8
                value |= UInt64(bytes[pos &+ 2]) << 16
                value |= UInt64(bytes[pos &+ 3]) << 24
                value |= UInt64(bytes[pos &+ 4]) << 32
                value |= UInt64(bytes[pos &+ 5]) << 40
                value |= UInt64(bytes[pos &+ 6]) << 48
                value |= UInt64(bytes[pos &+ 7]) << 56
                pos &+= 8
                return value
            }

            let m0 = try readByte()
            let m1 = try readByte()
            let m2 = try readByte()
            let m3 = try readByte()
            guard m0 == 0x46, m1 == 0x49, m2 == 0x44, m3 == 0x58 else {
                throw corrupted("CasefoldingCache decode: invalid magic")
            }

            let version = try readUInt32()
            guard version == 1 else {
                throw corrupted("CasefoldingCache decode: unsupported version \(version)")
            }

            let rawCount = Int(try readUInt32())
            let bucketCount = Int(try readUInt32())
            let seed1 = try readUInt32()
            let seed2 = try readUInt32()
            guard rawCount >= 0, bucketCount >= 0 else {
                throw corrupted("CasefoldingCache decode: invalid table sizes")
            }

            var rawTable: [UInt64] = []
            rawTable.reserveCapacity(rawCount)
            for _ in 0..<rawCount {
                rawTable.append(try readUInt64())
            }

            var displacements: [Int32] = []
            displacements.reserveCapacity(bucketCount)
            for _ in 0..<bucketCount {
                displacements.append(Int32(bitPattern: try readUInt32()))
            }

            guard pos == bytes.count else {
                throw corrupted("CasefoldingCache decode: unexpected trailing data")
            }
            if rawCount == 0, bucketCount != 0 {
                throw corrupted("CasefoldingCache decode: empty table with buckets")
            }
            if rawCount > 0, bucketCount == 0 {
                throw corrupted("CasefoldingCache decode: missing buckets")
            }
            return CasefoldingCache(
                rawTable: rawTable,
                displacements: displacements,
                seed1: seed1,
                seed2: seed2
            )
        }
    }

    // MARK: - Packed Search Fields Serialization

    private static func serializePackedSearchFields(_ packed: PackedSearchFields) -> Data {
        var data = Data()
        data.reserveCapacity(
            4 + 4 +
            4 + (packed.prepared.count * 8 * 4) +
            4 + packed.fieldBytes.count +
            4 + (packed.fastFieldRefs.count * 8) +
            4 + (packed.foldFieldRefs.count * 8)
        )

        data.append(contentsOf: [0x50, 0x46, 0x54, 0x42]) // "PFTB"
        appendUInt32(&data, 1)

        appendUInt32(&data, UInt32(packed.prepared.count))
        for entry in packed.prepared {
            appendUInt32(&data, UInt32(entry.primaryFast.start))
            appendUInt32(&data, UInt32(entry.primaryFast.count))
            appendUInt32(&data, UInt32(entry.primaryFold.start))
            appendUInt32(&data, UInt32(entry.primaryFold.count))
            appendUInt32(&data, UInt32(entry.alternateFast.start))
            appendUInt32(&data, UInt32(entry.alternateFast.count))
            appendUInt32(&data, UInt32(entry.alternateFold.start))
            appendUInt32(&data, UInt32(entry.alternateFold.count))
        }

        appendUInt32(&data, UInt32(packed.fieldBytes.count))
        data.append(contentsOf: packed.fieldBytes)

        appendUInt32(&data, UInt32(packed.fastFieldRefs.count))
        for ref in packed.fastFieldRefs {
            appendUInt32(&data, UInt32(ref.offset))
            appendUInt32(&data, UInt32(ref.length))
        }

        appendUInt32(&data, UInt32(packed.foldFieldRefs.count))
        for ref in packed.foldFieldRefs {
            appendUInt32(&data, UInt32(ref.offset))
            appendUInt32(&data, UInt32(ref.length))
        }

        return data
    }

    private static func deserializePackedSearchFields(_ data: Data) throws -> PackedSearchFields {
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var pos = 0

            func corrupted(_ description: String) -> Error {
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
            }

            func readByte() throws -> UInt8 {
                guard pos < bytes.count else { throw corrupted("PackedSearchFields decode: truncated byte") }
                let value = bytes[pos]
                pos &+= 1
                return value
            }

            func readUInt32() throws -> UInt32 {
                guard pos &+ 4 <= bytes.count else { throw corrupted("PackedSearchFields decode: truncated UInt32") }
                let value = UInt32(bytes[pos])
                    | (UInt32(bytes[pos &+ 1]) << 8)
                    | (UInt32(bytes[pos &+ 2]) << 16)
                    | (UInt32(bytes[pos &+ 3]) << 24)
                pos &+= 4
                return value
            }

            func readBytes(count: Int) throws -> [UInt8] {
                guard count >= 0, pos &+ count <= bytes.count else {
                    throw corrupted("PackedSearchFields decode: truncated byte range")
                }
                let range = pos..<(pos &+ count)
                pos &+= count
                return Array(bytes[range])
            }

            let m0 = try readByte()
            let m1 = try readByte()
            let m2 = try readByte()
            let m3 = try readByte()
            guard m0 == 0x50, m1 == 0x46, m2 == 0x54, m3 == 0x42 else {
                throw corrupted("PackedSearchFields decode: invalid magic")
            }

            let version = try readUInt32()
            guard version == 1 else {
                throw corrupted("PackedSearchFields decode: unsupported version \(version)")
            }

            let cityCount = Int(try readUInt32())
            guard cityCount >= 0 else {
                throw corrupted("PackedSearchFields decode: invalid city count")
            }

            var prepared: [PreparedSearchFields] = []
            prepared.reserveCapacity(cityCount)
            for _ in 0..<cityCount {
                let primaryFast = FieldSpan(start: Int(try readUInt32()), count: Int(try readUInt32()))
                let primaryFold = FieldSpan(start: Int(try readUInt32()), count: Int(try readUInt32()))
                let alternateFast = FieldSpan(start: Int(try readUInt32()), count: Int(try readUInt32()))
                let alternateFold = FieldSpan(start: Int(try readUInt32()), count: Int(try readUInt32()))
                prepared.append(PreparedSearchFields(
                    primaryFast: primaryFast,
                    primaryFold: primaryFold,
                    alternateFast: alternateFast,
                    alternateFold: alternateFold
                ))
            }

            let fieldByteCount = Int(try readUInt32())
            let fieldBytes = try readBytes(count: fieldByteCount)

            let fastFieldCount = Int(try readUInt32())
            guard fastFieldCount >= 0 else {
                throw corrupted("PackedSearchFields decode: invalid fast field count")
            }
            var fastFieldRefs: [FastFieldRef] = []
            fastFieldRefs.reserveCapacity(fastFieldCount)
            for _ in 0..<fastFieldCount {
                fastFieldRefs.append(FastFieldRef(offset: Int(try readUInt32()), length: Int(try readUInt32())))
            }

            let foldFieldCount = Int(try readUInt32())
            guard foldFieldCount >= 0 else {
                throw corrupted("PackedSearchFields decode: invalid fold field count")
            }
            var foldFieldRefs: [FoldFieldRef] = []
            foldFieldRefs.reserveCapacity(foldFieldCount)
            for _ in 0..<foldFieldCount {
                foldFieldRefs.append(FoldFieldRef(offset: Int(try readUInt32()), length: Int(try readUInt32())))
            }

            guard pos == bytes.count else {
                throw corrupted("PackedSearchFields decode: unexpected trailing data")
            }

            func validateSpan(_ span: FieldSpan, limit: Int) throws {
                guard span.start >= 0, span.count >= 0, span.start &+ span.count <= limit else {
                    throw corrupted("PackedSearchFields decode: span out of bounds")
                }
            }

            for entry in prepared {
                try validateSpan(entry.primaryFast, limit: fastFieldRefs.count)
                try validateSpan(entry.primaryFold, limit: foldFieldRefs.count)
                try validateSpan(entry.alternateFast, limit: fastFieldRefs.count)
                try validateSpan(entry.alternateFold, limit: foldFieldRefs.count)
            }

            for ref in fastFieldRefs {
                guard ref.offset >= 0, ref.length >= 0, ref.offset &+ ref.length <= fieldBytes.count else {
                    throw corrupted("PackedSearchFields decode: fast field ref out of bounds")
                }
            }
            for ref in foldFieldRefs {
                guard ref.offset >= 0, ref.length >= 0, ref.offset &+ ref.length <= fieldBytes.count else {
                    throw corrupted("PackedSearchFields decode: fold field ref out of bounds")
                }
            }

            return PackedSearchFields(
                prepared: prepared,
                fieldBytes: fieldBytes,
                fastFieldRefs: fastFieldRefs,
                foldFieldRefs: foldFieldRefs
            )
        }
    }

    // MARK: - Search Index Serialization

    private static func serializeSearchIndex(_ index: SearchIndex) -> Data {
        var data = Data()
        data.reserveCapacity(
            4 + 4 + 4 + 4 +
            4 + (index.bitmapBuf.count * 8) +
            4 + index.varintBuf.count +
            (128 * 8) + (128 * 4) +
            4 + 4 +
            (index.nonAsciiRefs.count * 8) +
            (index.nonAsciiCounts.count * 4)
        )

        data.append(contentsOf: [0x53, 0x49, 0x44, 0x58]) // "SIDX"
        appendUInt32(&data, 1) // format version
        appendUInt32(&data, UInt32(index.cityCount))
        appendUInt32(&data, UInt32(index.wordCount))

        appendUInt32(&data, UInt32(index.bitmapBuf.count))
        for word in index.bitmapBuf {
            appendUInt64(&data, word)
        }

        appendUInt32(&data, UInt32(index.varintBuf.count))
        data.append(contentsOf: index.varintBuf)

        for ref in index.asciiRefs {
            appendUInt32(&data, ref.offset)
            appendUInt32(&data, ref.packed)
        }
        for count in index.asciiCounts {
            appendUInt32(&data, count)
        }

        appendUInt32(&data, UInt32(index.nonAsciiKeys.count))
        var keyDeltaData = Data()
        keyDeltaData.reserveCapacity(index.nonAsciiKeys.count * 2)
        var prev: UInt32 = 0
        for key in index.nonAsciiKeys {
            appendVarUInt32(&keyDeltaData, key &- prev)
            prev = key
        }
        appendUInt32(&data, UInt32(keyDeltaData.count))
        data.append(keyDeltaData)

        for ref in index.nonAsciiRefs {
            appendUInt32(&data, ref.offset)
            appendUInt32(&data, ref.packed)
        }
        for count in index.nonAsciiCounts {
            appendUInt32(&data, count)
        }

        return data
    }

    private static func deserializeSearchIndex(_ data: Data) throws -> SearchIndex {
        let decoded: (Int, Int, [UInt64], [UInt8], [SearchIndex.Ref], [UInt32], [UInt32], [SearchIndex.Ref], [UInt32]) =
            try data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var pos = 0

                func corrupted(_ description: String) -> Error {
                    DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: description))
                }

                func readByte() throws -> UInt8 {
                    guard pos < bytes.count else { throw corrupted("SearchIndex decode: truncated byte") }
                    let value = bytes[pos]
                    pos &+= 1
                    return value
                }

                func readUInt32() throws -> UInt32 {
                    guard pos &+ 4 <= bytes.count else { throw corrupted("SearchIndex decode: truncated UInt32") }
                    let value = UInt32(bytes[pos])
                        | (UInt32(bytes[pos &+ 1]) << 8)
                        | (UInt32(bytes[pos &+ 2]) << 16)
                        | (UInt32(bytes[pos &+ 3]) << 24)
                    pos &+= 4
                    return value
                }

                func readUInt64() throws -> UInt64 {
                    guard pos &+ 8 <= bytes.count else { throw corrupted("SearchIndex decode: truncated UInt64") }
                    var value: UInt64 = 0
                    value |= UInt64(bytes[pos])
                    value |= UInt64(bytes[pos &+ 1]) << 8
                    value |= UInt64(bytes[pos &+ 2]) << 16
                    value |= UInt64(bytes[pos &+ 3]) << 24
                    value |= UInt64(bytes[pos &+ 4]) << 32
                    value |= UInt64(bytes[pos &+ 5]) << 40
                    value |= UInt64(bytes[pos &+ 6]) << 48
                    value |= UInt64(bytes[pos &+ 7]) << 56
                    pos &+= 8
                    return value
                }

                func readBytes(count: Int) throws -> [UInt8] {
                    guard count >= 0, pos &+ count <= bytes.count else {
                        throw corrupted("SearchIndex decode: truncated byte range")
                    }
                    let range = pos..<(pos &+ count)
                    pos &+= count
                    return Array(bytes[range])
                }

                func readVarUInt32(_ source: [UInt8], _ varintPos: inout Int) throws -> UInt32 {
                    var result: UInt32 = 0
                    var shift: UInt32 = 0
                    while true {
                        guard varintPos < source.count else {
                            throw corrupted("SearchIndex decode: truncated varint")
                        }
                        let byte = source[varintPos]
                        varintPos &+= 1
                        result |= UInt32(byte & 0x7F) << shift
                        if byte & 0x80 == 0 { return result }
                        shift &+= 7
                        if shift >= 35 {
                            throw corrupted("SearchIndex decode: invalid varint")
                        }
                    }
                }

                let m0 = try readByte()
                let m1 = try readByte()
                let m2 = try readByte()
                let m3 = try readByte()
                guard m0 == 0x53, m1 == 0x49, m2 == 0x44, m3 == 0x58 else {
                    throw corrupted("SearchIndex decode: invalid magic")
                }

                let version = try readUInt32()
                guard version == 1 else {
                    throw corrupted("SearchIndex decode: unsupported version \(version)")
                }

                let cityCount = Int(try readUInt32())
                let wordCount = Int(try readUInt32())
                guard cityCount >= 0, wordCount >= 0 else {
                    throw corrupted("SearchIndex decode: invalid counts")
                }
                guard wordCount == (cityCount + 63) / 64 else {
                    throw corrupted("SearchIndex decode: wordCount mismatch")
                }

                let bitmapWordCount = Int(try readUInt32())
                var bitmapBuf = [UInt64](repeating: 0, count: bitmapWordCount)
                for i in 0..<bitmapWordCount {
                    bitmapBuf[i] = try readUInt64()
                }

                let varintCount = Int(try readUInt32())
                let varintBuf = try readBytes(count: varintCount)

                var asciiRefs = [SearchIndex.Ref](repeating: .empty, count: 128)
                for i in 0..<128 {
                    let offset = try readUInt32()
                    let packed = try readUInt32()
                    asciiRefs[i] = SearchIndex.Ref(offset: offset, packed: packed)
                }

                var asciiCounts = [UInt32](repeating: 0, count: 128)
                for i in 0..<128 {
                    asciiCounts[i] = try readUInt32()
                }

                let nonAsciiCount = Int(try readUInt32())
                let keyDeltaByteCount = Int(try readUInt32())
                let keyDeltaBytes = try readBytes(count: keyDeltaByteCount)

                var nonAsciiKeys: [UInt32] = []
                nonAsciiKeys.reserveCapacity(nonAsciiCount)
                var keyPos = 0
                var prev: UInt32 = 0
                for _ in 0..<nonAsciiCount {
                    let delta = try readVarUInt32(keyDeltaBytes, &keyPos)
                    prev = prev &+ delta
                    nonAsciiKeys.append(prev)
                }
                guard keyPos == keyDeltaBytes.count else {
                    throw corrupted("SearchIndex decode: trailing nonAscii key bytes")
                }

                var nonAsciiRefs = [SearchIndex.Ref](repeating: .empty, count: nonAsciiCount)
                for i in 0..<nonAsciiCount {
                    let offset = try readUInt32()
                    let packed = try readUInt32()
                    nonAsciiRefs[i] = SearchIndex.Ref(offset: offset, packed: packed)
                }

                var nonAsciiCounts = [UInt32](repeating: 0, count: nonAsciiCount)
                for i in 0..<nonAsciiCount {
                    nonAsciiCounts[i] = try readUInt32()
                }

                guard pos == bytes.count else {
                    throw corrupted("SearchIndex decode: unexpected trailing data")
                }

                func validateRef(_ ref: SearchIndex.Ref) throws {
                    guard !ref.isEmpty else { return }
                    let offset = Int(ref.offset)
                    let length = ref.length
                    guard offset >= 0, length >= 0 else {
                        throw corrupted("SearchIndex decode: negative ref bounds")
                    }
                    if ref.isBitmap {
                        guard offset &+ length <= bitmapBuf.count else {
                            throw corrupted("SearchIndex decode: bitmap ref out of bounds")
                        }
                    } else {
                        guard offset &+ length <= varintBuf.count else {
                            throw corrupted("SearchIndex decode: varint ref out of bounds")
                        }
                    }
                }

                for ref in asciiRefs { try validateRef(ref) }
                for ref in nonAsciiRefs { try validateRef(ref) }

                return (
                    cityCount,
                    wordCount,
                    bitmapBuf,
                    varintBuf,
                    asciiRefs,
                    asciiCounts,
                    nonAsciiKeys,
                    nonAsciiRefs,
                    nonAsciiCounts
                )
            }

        return SearchIndex(
            cityCount: decoded.0,
            wordCount: decoded.1,
            bitmapBuf: decoded.2,
            varintBuf: decoded.3,
            asciiRefs: decoded.4,
            asciiCounts: decoded.5,
            nonAsciiKeys: decoded.6,
            nonAsciiRefs: decoded.7,
            nonAsciiCounts: decoded.8
        )
    }

    // MARK: - Binary Helpers

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendVarUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }
}
