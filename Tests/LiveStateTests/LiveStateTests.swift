import XCTest
@testable import LiveState
final class LiveStateTests:XCTestCase {
 func testStartRequestsOpeningQuestion(){let r=LiveStateReducer.reduce(state:.init(),event:.encounterStarted);XCTAssertEqual(r.state.lifecycle,.active);XCTAssertEqual(r.effects,[.requestCounterpartAction(.askOpeningQuestion)])}
 func testMissingTradeoffIsChallenged(){var s=EncounterState(lifecycle:.active);let a=LiveStateReducer.reduce(state:s,event:.userSubmitted("Next.js improved discoverability."));s=a.state;guard case let .evaluateAnswer(id,_)=a.effects.first else{return XCTFail()};let r=LiveStateReducer.reduce(state:s,event:.answerEvaluated(turnID:id,.init(answeredQuestion:true,specificity:0.8,tradeoffMentioned:false)));XCTAssertTrue(r.effects.contains(.requestCounterpartAction(.challengeTradeoff)))}
 func testRestorePreservesHistoryAndCreatesBranch(){var s=EncounterState(lifecycle:.active);s.turns.append(.init(speaker:.counterpart,text:"Why didn't you use Redux?"));let old=s.activeBranchID;let restored=Branching.restore(Branching.checkpoint(s));XCTAssertEqual(restored.turns,s.turns);XCTAssertNotEqual(restored.activeBranchID,old)}
}