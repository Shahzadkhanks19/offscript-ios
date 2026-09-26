import Foundation

public struct RecordedEvent: Equatable, Sendable {
    public let sequence: Int
    public let event: SimulationEvent
    public init(sequence: Int, event: SimulationEvent) { self.sequence = sequence; self.event = event }
    public init(_ record: EventRecord) { self.sequence = record.sequence; self.event = record.event }
}

public enum ReplayEngine {
    public static func replay(initial: EncounterState, events: [RecordedEvent]) -> EncounterState {
        events.sorted { $0.sequence < $1.sequence }.reduce(initial) { state, record in
            LiveStateReducer.reduce(state: state, event: record.event).state
        }
    }

    public static func replay(initial: EncounterState, records: [EventRecord]) -> EncounterState {
        replay(initial: initial, events: records.map(RecordedEvent.init))
    }
}

public struct BranchComparison: Equatable, Sendable {
    public let originalBranchID: UUID
    public let retryBranchID: UUID
    public let objectiveStatusChanges: [String: ObjectiveStatus]
    public let originalTurnCount: Int
    public let retryTurnCount: Int
}

public enum BranchComparator {
    public static func compare(original: EncounterState, retry: EncounterState) -> BranchComparison {
        var changes: [String: ObjectiveStatus] = [:]
        for objective in retry.objectives {
            let previous = original.objectives.first { $0.id == objective.id }?.status
            if previous != objective.status { changes[objective.id] = objective.status }
        }
        return .init(
            originalBranchID: original.activeBranchID,
            retryBranchID: retry.activeBranchID,
            objectiveStatusChanges: changes,
            originalTurnCount: original.conversation.turns.count,
            retryTurnCount: retry.conversation.turns.count
        )
    }
}
