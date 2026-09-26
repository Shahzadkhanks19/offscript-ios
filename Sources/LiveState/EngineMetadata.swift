import Foundation

public struct EngineMetadata: Equatable, Sendable, Codable {
    public static let currentEngineVersion = "1.0.0-m1"
    public static let currentStateSchemaVersion = 1

    public var engineVersion: String
    public var stateSchemaVersion: Int

    public init(
        engineVersion: String = EngineMetadata.currentEngineVersion,
        stateSchemaVersion: Int = EngineMetadata.currentStateSchemaVersion
    ) {
        self.engineVersion = engineVersion
        self.stateSchemaVersion = stateSchemaVersion
    }
}
