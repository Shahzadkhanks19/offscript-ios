import LiveState
var state=EncounterState()
var result=LiveStateReducer.reduce(state:state,event:.encounterStarted); state=result.state
print("Offscript — LiveState Playground")
print("Scenario: \(state.scenarioTitle)")
let answer="We chose Next.js because server rendering helped pages where discoverability mattered."
result=LiveStateReducer.reduce(state:state,event:.userSubmitted(answer)); state=result.state
guard case let .evaluateAnswer(turnID,_)=result.effects.first else{fatalError("Expected evaluation")}
result=LiveStateReducer.reduce(state:state,event:.answerEvaluated(turnID:turnID,.init(answeredQuestion:true,specificity:0.72,tradeoffMentioned:false)))
print(result.effects)
