import Foundation

public struct BranchLineage: Equatable, Sendable, Codable {
    public var parentCheckpointByBranch: [UUID: UUID]

    public init(parentCheckpointByBranch: [UUID: UUID] = [:]) {
        self.parentCheckpointByBranch = parentCheckpointByBranch
    }

    public mutating func register(branchID: UUID, parentCheckpointID: UUID) {
        parentCheckpointByBranch[branchID] = parentCheckpointID
    }

    public func parentCheckpointID(for branchID: UUID) -> UUID? {
        parentCheckpointByBranch[branchID]
    }
}
