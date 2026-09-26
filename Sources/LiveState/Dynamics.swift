import Foundation

public struct CounterpartDelta: Equatable, Sendable {
    public var patience: Double = 0
    public var skepticism: Double = 0
    public var engagement: Double = 0
    public var rapport: Double = 0
    public init(patience: Double = 0, skepticism: Double = 0, engagement: Double = 0, rapport: Double = 0) {
        self.patience = patience; self.skepticism = skepticism; self.engagement = engagement; self.rapport = rapport
    }
}

public enum CounterpartDynamics {
    public static func delta(for evaluation: AnswerEvaluation) -> CounterpartDelta {
        var delta = CounterpartDelta()
        if !evaluation.answeredQuestion || evaluation.relevance < 0.45 {
            delta.patience -= 0.08; delta.skepticism += 0.10; delta.engagement -= 0.06
        } else if evaluation.specificity < 0.55 {
            delta.skepticism += 0.06; delta.engagement -= 0.02
        } else {
            delta.skepticism -= 0.04; delta.engagement += 0.06; delta.rapport += 0.03
        }
        return delta
    }

    public static func apply(_ delta: CounterpartDelta, to counterpart: inout CounterpartState) {
        counterpart.patience = clamp(counterpart.patience + delta.patience)
        counterpart.skepticism = clamp(counterpart.skepticism + delta.skepticism)
        counterpart.engagement = clamp(counterpart.engagement + delta.engagement)
        counterpart.rapport = clamp(counterpart.rapport + delta.rapport)
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

public enum PressureEngine {
    public static func adaptiveDelta(for evaluation: AnswerEvaluation) -> Double {
        if !evaluation.answeredQuestion || evaluation.relevance < 0.45 { return -0.08 }
        if evaluation.specificity >= 0.75 { return 0.05 }
        return 0
    }
}
