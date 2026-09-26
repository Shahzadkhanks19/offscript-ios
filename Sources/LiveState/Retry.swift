import Foundation

public struct RetrySession: Equatable, Sendable {
    public let checkpointID: UUID
    public let original: EncounterState
    public let retry: EncounterState
    public init(checkpointID: UUID, original: EncounterState, retry: EncounterState) {
        self.checkpointID = checkpointID; self.original = original; self.retry = retry
    }
}

public enum RetryEngine {
    public static func begin(from checkpoint: Checkpoint, original: EncounterState) -> RetrySession {
        let branchID = Determinism.branchID(
            encounterID: original.id,
            parentBranchID: checkpoint.parentBranchID,
            checkpointID: checkpoint.id,
            sequence: original.sequence + 1
        )
        var retry = Branching.restore(checkpoint, branchID: branchID)
        retry.sequence = original.sequence
        retry.branchLineage.register(branchID: branchID, parentCheckpointID: checkpoint.id)
        return .init(checkpointID: checkpoint.id, original: original, retry: retry)
    }

    public static func compare(_ session: RetrySession, retryState: EncounterState) -> BranchComparison {
        BranchComparator.compare(original: session.original, retry: retryState)
    }
}
