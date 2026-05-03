import Foundation

public enum WorldCitiesDBError: Error, Equatable {
    case resourceNotFound(String)
}

/// Provides read-only access to the bundled world cities database.
///
/// Generic over the city type: users define their own struct with only the fields they need.
/// Cities are pre-sorted by population descending in the binary city file.
public final class WorldCitiesDB<C: CityRepresentable> {

    /// All cities sorted by population descending.
    public let cities: [C]
    /// Metadata stored with the canonical city file.
    public let metadata: CityDatabaseMetadata
    /// Prebuilt casefold cache bundled into the city database file.
    public let casefoldingCache: CasefoldingCache
    /// Prebuilt search index bundled into the city database file.
    public let searchIndex: SearchIndex
    /// Prebuilt packed search field table bundled into the city database file.
    public let packedSearchFields: PackedSearchFields

    /// Total number of cities.
    public var count: Int { cities.count }

    /// Creates a new instance using the bundled city data and search artifacts.
    public convenience init() throws {
        guard let cityURL = Bundle.module.url(
            forResource: "cities",
            withExtension: "wcdb",
            subdirectory: "Resources"
        ) else {
            throw WorldCitiesDBError.resourceNotFound("Resources/cities.wcdb")
        }

        try self.init(data: Data(contentsOf: cityURL))
    }

    /// Creates an instance from a pre-loaded city database file.
    public init(data: Data) throws {
        let decoded: DecodedCityDatabase<C> = try CityDatabaseFile.decode(from: data)

        self.cities = decoded.cities
        self.metadata = decoded.metadata
        self.casefoldingCache = decoded.searchArtifacts.casefoldingCache
        self.searchIndex = decoded.searchArtifacts.searchIndex
        self.packedSearchFields = decoded.searchArtifacts.packedSearchFields
    }
}
