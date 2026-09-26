import Foundation

public struct Checkpoint: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let parentBranchID: UUID
    public let state: EncounterState
    public init(id: UUID = UUID(), parentBranchID: UUID, state: EncounterState) {
        self.id = id; self.parentBranchID = parentBranchID; self.state = state
    }
}

public struct Branch: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let parentCheckpointID: UUID?
    public init(id: UUID = UUID(), parentCheckpointID: UUID? = nil) {
        self.id = id; self.parentCheckpointID = parentCheckpointID
    }
}

public enum Branching {
    public static func checkpoint(_ state: EncounterState) -> Checkpoint {
        Checkpoint(parentBranchID: state.activeBranchID, state: state)
    }
    public static func restore(_ checkpoint: Checkpoint) -> EncounterState {
        var restored = checkpoint.state
        restored.activeBranchID = UUID()
        restored.lifecycle = .active
        return restored
    }
}
