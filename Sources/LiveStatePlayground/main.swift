import LiveState

var state = EncounterState()
var result = LiveStateReducer.reduce(state: state, event: .encounterStarted)
state = result.state

print("Offscript — LiveState Playground")
print("Scenario: \(state.scenario.title)")
print("Counterpart: \(state.counterpart.name), \(state.counterpart.role)")
print("Opening policy: \(result.effects)")

let answer = "We chose Next.js because server rendering helped discoverability, while accepting additional server complexity."
result = LiveStateReducer.reduce(state: state, event: .userSubmitted(answer))
state = result.state
print("\nYou: \(answer)")

guard case let .evaluateAnswer(turnID, _) = result.effects.first(where: {
    if case .evaluateAnswer = $0 { return true }
    return false
}) else {
    fatalError("Expected semantic evaluation effect")
}

let evaluation = AnswerEvaluation(
    answeredQuestion: true,
    relevance: 0.94,
    specificity: 0.82,
    objectiveEvaluations: [
        .init(objectiveID: "architectureReasoning", status: .satisfied, reason: "Explained why SSR mattered.", confidence: 0.95),
        .init(objectiveID: "tradeoffAwareness", status: .satisfied, reason: "Acknowledged server complexity.", confidence: 0.91)
    ]
)

result = LiveStateReducer.reduce(state: state, event: .answerEvaluated(turnID: turnID, evaluation))
state = result.state

print("\nObjectives:")
for objective in state.objectives {
    print("  \(objective.id): \(objective.status.rawValue)")
}
print("Next policy: \(result.effects)")
print("Event sequence: \(state.sequence)")
