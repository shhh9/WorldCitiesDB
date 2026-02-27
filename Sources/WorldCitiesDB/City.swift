import Foundation

/// A city from the GeoNames cities500 dataset.
///
/// Contains all cities with a population greater than 500 or that are seats
/// of administrative divisions (approximately 185,000 entries worldwide).
public struct City: Codable, Identifiable, Sendable {
    /// GeoNames unique identifier
    public var id: Int { geonameId }

    public let geonameId: Int
    public let name: String
    public let asciiName: String
    public let alternateNames: [String]
    public let latitude: Double
    public let longitude: Double
    public let featureClass: String?
    public let featureCode: String?
    public let countryCode: String
    public let cc2: [String]
    public let admin1Code: String?
    public let admin2Code: String?
    public let admin3Code: String?
    public let admin4Code: String?
    public let population: Int
    public let elevation: Int?
    public let dem: Int?
    public let timezone: String?
    public let modificationDate: Date?

    public init(
        geonameId: Int, name: String, asciiName: String, alternateNames: [String],
        latitude: Double, longitude: Double, featureClass: String?, featureCode: String?,
        countryCode: String, cc2: [String], admin1Code: String?, admin2Code: String?,
        admin3Code: String?, admin4Code: String?, population: Int, elevation: Int?,
        dem: Int?, timezone: String?, modificationDate: Date?
    ) {
        self.geonameId = geonameId
        self.name = name
        self.asciiName = asciiName
        self.alternateNames = alternateNames
        self.latitude = latitude
        self.longitude = longitude
        self.featureClass = featureClass
        self.featureCode = featureCode
        self.countryCode = countryCode
        self.cc2 = cc2
        self.admin1Code = admin1Code
        self.admin2Code = admin2Code
        self.admin3Code = admin3Code
        self.admin4Code = admin4Code
        self.population = population
        self.elevation = elevation
        self.dem = dem
        self.timezone = timezone
        self.modificationDate = modificationDate
    }
}

/// A search result containing the matched city and details about which fields matched.
public struct SearchResult: Sendable {
    /// The matched city.
    public let city: City
    /// Whether the query matched the city's `name` field.
    public let matchedName: Bool
    /// Whether the query matched the city's `asciiName` field.
    public let matchedAsciiName: Bool
    /// The alternate names that matched the query.
    public let matchedAlternateNames: [String]

    /// Whether the match was in name or asciiName (as opposed to only in alternateNames).
    public var matchedPrimaryName: Bool { matchedName || matchedAsciiName }
}
