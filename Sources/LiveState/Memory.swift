import Foundation

public struct MemoryItem: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let sourceTurnID: UUID
    public let topic: String
    public let summary: String
    public let importance: Double
    public init(id: UUID = UUID(), sourceTurnID: UUID, topic: String, summary: String, importance: Double) {
        self.id = id; self.sourceTurnID = sourceTurnID; self.topic = topic; self.summary = summary
        self.importance = min(max(importance, 0), 1)
    }
}

public enum CounterpartMemory {
    public static func derive(turnID: UUID, evaluation: AnswerEvaluation, id: (Int) -> UUID = { _ in UUID() }) -> [MemoryItem] {
        evaluation.objectiveEvaluations
            .filter { $0.status != .unresolved && $0.confidence >= 0.6 }
            .enumerated()
            .map { index, value in
                MemoryItem(id: id(index), sourceTurnID: turnID, topic: value.objectiveID, summary: value.reason, importance: value.confidence)
            }
    }

    public static func merge(_ incoming: [MemoryItem], into existing: inout [MemoryItem], limit: Int = 12) {
        for item in incoming {
            if let index = existing.firstIndex(where: { $0.topic == item.topic }) {
                if item.importance >= existing[index].importance { existing[index] = item }
            } else {
                existing.append(item)
            }
        }
        existing = Array(existing.sorted { $0.importance > $1.importance }.prefix(limit))
    }
}
