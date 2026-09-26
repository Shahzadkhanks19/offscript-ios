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
        .init(checkpointID: checkpoint.id, original: original, retry: Branching.restore(checkpoint))
    }

    public static func compare(_ session: RetrySession, retryState: EncounterState) -> BranchComparison {
        BranchComparator.compare(original: session.original, retry: retryState)
    }
}
