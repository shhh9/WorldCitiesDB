import Foundation

/// A city from the GeoNames cities500 dataset with all fields.
public struct City: CityRepresentable, SearchableCity, Identifiable, Sendable {
    /// GeoNames unique identifier
    public var id: Int { geonameId }

    public let geonameId: Int
    public let name: String
    public let asciiName: String
    /// Non-ASCII alternate names.
    public let alternateNames: [String]
    /// ASCII-only alternate names.
    public let alternateAsciiNames: [String]
    public let latitude: Double
    public let longitude: Double
    public let featureClass: String?
    public let featureCode: String?
    public let countryCode: String
    public let cc2: [String]
    public let admin1Code: String?
    public let admin1Name: String?
    public let admin2Code: String?
    public let admin2Name: String?
    public let admin3Code: String?
    public let admin4Code: String?
    public let population: Int
    public let elevation: Int?
    public let dem: Int?
    public let timezone: String?
    public let modificationDate: Date?

    public init(
        geonameId: Int, name: String, asciiName: String,
        alternateNames: [String], alternateAsciiNames: [String],
        latitude: Double, longitude: Double, featureClass: String?, featureCode: String?,
        countryCode: String, cc2: [String], admin1Code: String?, admin1Name: String?,
        admin2Code: String?, admin2Name: String?, admin3Code: String?, admin4Code: String?,
        population: Int,
        elevation: Int?, dem: Int?, timezone: String?, modificationDate: Date?
    ) {
        self.geonameId = geonameId
        self.name = name
        self.asciiName = asciiName
        self.alternateNames = alternateNames
        self.alternateAsciiNames = alternateAsciiNames
        self.latitude = latitude
        self.longitude = longitude
        self.featureClass = featureClass
        self.featureCode = featureCode
        self.countryCode = countryCode
        self.cc2 = cc2
        self.admin1Code = admin1Code
        self.admin1Name = admin1Name
        self.admin2Code = admin2Code
        self.admin2Name = admin2Name
        self.admin3Code = admin3Code
        self.admin4Code = admin4Code
        self.population = population
        self.elevation = elevation
        self.dem = dem
        self.timezone = timezone
        self.modificationDate = modificationDate
    }

    // MARK: - CityRepresentable

    public init(from fields: borrowing CityFields) {
        self.geonameId = fields.geonameId
        self.name = fields.name()
        self.asciiName = fields.asciiName()
        self.alternateNames = fields.alternateNames()
        self.alternateAsciiNames = fields.alternateAsciiNames()
        self.latitude = fields.latitude
        self.longitude = fields.longitude
        self.featureClass = fields.featureClass()
        self.featureCode = fields.featureCode()
        self.countryCode = fields.countryCode()
        self.cc2 = fields.cc2()
        self.admin1Code = fields.admin1Code()
        self.admin1Name = fields.admin1Name()
        self.admin2Code = fields.admin2Code()
        self.admin2Name = fields.admin2Name()
        self.admin3Code = fields.admin3Code()
        self.admin4Code = fields.admin4Code()
        self.population = fields.population
        self.elevation = fields.elevation
        self.dem = fields.dem
        self.timezone = fields.timezone()
        self.modificationDate = fields.modificationDate
    }

    // MARK: - SearchableCity

    public func matchesPrimaryField(_ test: (String) -> Bool) -> Bool {
        test(asciiName) || test(name)
    }

    public func matchesAlternateField(_ test: (String) -> Bool) -> Bool {
        alternateAsciiNames.contains(where: test) || alternateNames.contains(where: test)
    }

    // MARK: - Debug

    /// Dumps and prints all city fields in declaration order.
    public func printCity(indent: String = "  ") {
        print("\(indent)id: \(id)")
        for child in Mirror(reflecting: self).children {
            guard let label = child.label else { continue }
            print("\(indent)\(label): \(String(describing: child.value))")
        }
    }
}
