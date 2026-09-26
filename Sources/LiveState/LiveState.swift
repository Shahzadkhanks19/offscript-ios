import Foundation

public enum Speaker:String,Sendable,Codable { case user,counterpart }
public enum EncounterLifecycle:String,Sendable,Codable { case created,active,paused,completed,failed }
public enum ObjectiveStatus:String,Sendable,Codable { case unresolved,partial,satisfied }

public struct Objective:Identifiable,Equatable,Sendable,Codable {
 public let id:String; public var status:ObjectiveStatus; public var evidenceTurnIDs:[UUID]
 public init(id:String,status:ObjectiveStatus = .unresolved,evidenceTurnIDs:[UUID] = []) { self.id=id; self.status=status; self.evidenceTurnIDs=evidenceTurnIDs }
}
public struct ConversationTurn:Identifiable,Equatable,Sendable,Codable {
 public let id:UUID; public let speaker:Speaker; public let text:String
 public init(id:UUID=UUID(),speaker:Speaker,text:String){self.id=id;self.speaker=speaker;self.text=text}
}
public struct CounterpartState:Equatable,Sendable,Codable {
 public var name:String; public var role:String; public var patience:Double; public var skepticism:Double
 public init(name:String="Maya Chen",role:String="Senior Engineering Manager",patience:Double=0.65,skepticism:Double=0.55){self.name=name;self.role=role;self.patience=patience;self.skepticism=skepticism}
}
public struct EncounterState:Equatable,Sendable,Codable {
 public let id:UUID; public var lifecycle:EncounterLifecycle; public var scenarioTitle:String; public var counterpart:CounterpartState
 public var turns:[ConversationTurn]; public var objectives:[Objective]; public var activeBranchID:UUID
 public init(id:UUID=UUID(),lifecycle:EncounterLifecycle = .created,scenarioTitle:String="Frontend Developer Interview",counterpart:CounterpartState = .init(),turns:[ConversationTurn]=[],objectives:[Objective]=[.init(id:"architectureReasoning"),.init(id:"tradeoffAwareness"),.init(id:"productionExperience")],activeBranchID:UUID=UUID()){self.id=id;self.lifecycle=lifecycle;self.scenarioTitle=scenarioTitle;self.counterpart=counterpart;self.turns=turns;self.objectives=objectives;self.activeBranchID=activeBranchID}
}
public struct AnswerEvaluation:Equatable,Sendable {
 public var answeredQuestion:Bool; public var specificity:Double; public var tradeoffMentioned:Bool
 public init(answeredQuestion:Bool,specificity:Double,tradeoffMentioned:Bool){self.answeredQuestion=answeredQuestion;self.specificity=specificity;self.tradeoffMentioned=tradeoffMentioned}
}
public enum PolicyAction:Equatable,Sendable { case askOpeningQuestion,acknowledgeAndContinue,challengeTradeoff,askForSpecificExample,endEncounter }
public struct Checkpoint:Identifiable,Equatable,Sendable {
 public let id:UUID; public let parentBranchID:UUID; public let state:EncounterState
 public init(id:UUID=UUID(),parentBranchID:UUID,state:EncounterState){self.id=id;self.parentBranchID=parentBranchID;self.state=state}
}
public enum SimulationEvent:Equatable,Sendable { case encounterStarted,userSubmitted(String),counterpartResponded(String),answerEvaluated(turnID:UUID,AnswerEvaluation),checkpointRestored(Checkpoint),encounterCompleted }
public enum SimulationEffect:Equatable,Sendable { case evaluateAnswer(turnID:UUID,text:String),requestCounterpartAction(PolicyAction),persistCheckpoint(Checkpoint) }

public enum PolicyEngine {
 public static func nextAction(evaluation:AnswerEvaluation?)->PolicyAction {
  guard let e=evaluation else{return .askOpeningQuestion}
  if !e.answeredQuestion{return .askForSpecificExample}
  if !e.tradeoffMentioned{return .challengeTradeoff}
  if e.specificity < 0.55{return .askForSpecificExample}
  return .acknowledgeAndContinue
 }
}
public enum Branching {
 public static func checkpoint(_ state:EncounterState)->Checkpoint { Checkpoint(parentBranchID:state.activeBranchID,state:state) }
 public static func restore(_ checkpoint:Checkpoint)->EncounterState { var s=checkpoint.state;s.activeBranchID=UUID();return s }
}
public struct Reduction:Sendable { public var state:EncounterState; public var effects:[SimulationEffect] }

public enum LiveStateReducer {
 public static func reduce(state:EncounterState,event:SimulationEvent)->Reduction {
  var next=state
  switch event {
  case .encounterStarted:
   next.lifecycle = .active; return .init(state:next,effects:[.requestCounterpartAction(.askOpeningQuestion)])
  case let .userSubmitted(text):
   let turn=ConversationTurn(speaker:.user,text:text); next.turns.append(turn); return .init(state:next,effects:[.evaluateAnswer(turnID:turn.id,text:text)])
  case let .counterpartResponded(text):
   next.turns.append(.init(speaker:.counterpart,text:text)); return .init(state:next,effects:[])
  case let .answerEvaluated(turnID,e):
   if e.answeredQuestion { update("architectureReasoning",.satisfied,turnID,&next) }
   if e.tradeoffMentioned { update("tradeoffAwareness",.satisfied,turnID,&next) }
   let cp=Branching.checkpoint(next); return .init(state:next,effects:[.persistCheckpoint(cp),.requestCounterpartAction(PolicyEngine.nextAction(evaluation:e))])
  case let .checkpointRestored(cp): return .init(state:Branching.restore(cp),effects:[])
  case .encounterCompleted: next.lifecycle = .completed; return .init(state:next,effects:[])
  }
 }
 private static func update(_ id:String,_ status:ObjectiveStatus,_ evidence:UUID,_ state:inout EncounterState){guard let i=state.objectives.firstIndex(where:{$0.id==id}) else{return};state.objectives[i].status=status;state.objectives[i].evidenceTurnIDs.append(evidence)}
}