import Foundation

public struct WildlifeObservation: Codable, Identifiable, Sendable {
    public var id: UUID
    public var species: String
    public var observedAt: Date
    public var point: GeoPoint?
    public var accuracyMeters: Double?
    public var fixAt: Date?
    public var altitudeMeters: Double?
    public var groundID: String?
    public var groundName: String?
    public var count: Int
    public var notes: String
    public var photoJPEG: Data?
    public var weather: ObservationWeather?
    public init(id: UUID = UUID(), species: String, observedAt: Date = Date(), point: GeoPoint? = nil,
                accuracyMeters: Double? = nil, fixAt: Date? = nil, altitudeMeters: Double? = nil,
                groundID: String? = nil, groundName: String? = nil, count: Int = 1, notes: String = "",
                photoJPEG: Data? = nil, weather: ObservationWeather? = nil) {
        self.id=id;self.species=species;self.observedAt=observedAt;self.point=point
        self.accuracyMeters=accuracyMeters;self.fixAt=fixAt;self.altitudeMeters=altitudeMeters
        self.groundID=groundID;self.groundName=groundName;self.count=count;self.notes=notes
        self.photoJPEG=photoJPEG;self.weather=weather
    }
    public var valid: Bool {
        !species.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && species.count <= 200 &&
        (1...100000).contains(count) && notes.count <= 4000 &&
        (point?.valid ?? true) && (accuracyMeters.map { $0.isFinite && $0 >= 0 } ?? true) &&
        (altitudeMeters?.isFinite ?? true) && (photoJPEG?.count ?? 0) <= 2_000_000
    }
}
public struct ObservationWeather: Codable, Sendable {
    public let retrievedAt: Date
    public let forecastAt: Date
    public let temperatureC: Double?
    public let windKmh: Double?
    public let source: String
    public init(retrievedAt: Date, forecastAt: Date, temperatureC: Double?, windKmh: Double?, source: String) {
        self.retrievedAt=retrievedAt;self.forecastAt=forecastAt;self.temperatureC=temperatureC;self.windKmh=windKmh;self.source=source
    }
}
public enum ObservationValidation {
    public static func matches(_ value: WildlifeObservation, query: String) -> Bool {
        let q=query.trimmingCharacters(in:.whitespacesAndNewlines)
        return q.isEmpty || [value.species,value.notes,value.groundName ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
    }
    public static func export(_ values: [WildlifeObservation], includeLocations: Bool, includePhotos: Bool) throws -> Data {
        let sanitized=values.map { item -> WildlifeObservation in
            var copy=item
            if !includeLocations {copy.point=nil;copy.accuracyMeters=nil;copy.fixAt=nil;copy.altitudeMeters=nil;copy.groundID=nil;copy.groundName=nil}
            if !includePhotos {copy.photoJPEG=nil}
            return copy
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(sanitized)
    }
}
