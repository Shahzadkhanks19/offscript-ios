import LiveState

func describe(_ event: VoiceCaptureEvent) -> String {
    switch event {
    case let .activity(observation):
        return "activity: \(observation)"
    case let .transcript(transcript):
        return "transcript[u=\(transcript.utteranceID.map(String.init) ?? "nil"), r=\(transcript.revision), final=\(transcript.isFinal)]: \(transcript.text)"
    }
}

@discardableResult
func feed(
    _ input: VoiceCaptureAdapterInput,
    generation: VoiceCaptureGeneration,
    into machine: inout VoiceCaptureAdapterMachine,
    gate: inout VoiceActivityGate,
    counterpartIsSpeaking: Bool
) -> VoiceCaptureAdapterOutput {
    let output = machine.receive(input, generation: generation)
    if output.recoveryAction != .none {
        print("recovery: \(output.recoveryAction)")
    }

    for event in output.events {
        print("raw -> \(describe(event))")
        if case let .activity(observation) = event {
            for semantic in gate.receive(
                observation,
                counterpartIsSpeaking: counterpartIsSpeaking
            ) {
                print("semantic -> \(semantic)")
            }
        }
    }
    return output
}

print("Offscript — M2 Realtime Voice Playground")
print("Platform-neutral simulation of capture -> VAD -> transcript boundaries\n")

var machine = VoiceCaptureAdapterMachine()
var gate = VoiceActivityGate()

let firstGeneration = machine.beginGeneration()
_ = machine.receive(.session(.startRequested), generation: firstGeneration)
_ = machine.receive(.session(.captureStarted), generation: firstGeneration)
print("capture generation: \(firstGeneration.rawValue)")
print("capture: \(machine.state.session)\n")

print("1. User begins while Maya is speaking")
feed(
    .activity(.init(isSpeech: true, elapsedMilliseconds: 1_000)),
    generation: firstGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: true
)
feed(
    .activity(.init(isSpeech: true, elapsedMilliseconds: 1_180)),
    generation: firstGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: true
)
feed(
    .transcript(
        text: "We chose Next.js",
        isFinal: false,
        confidence: 0.91
    ),
    generation: firstGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .transcript(
        text: "We chose Next.js because server rendering helped discoverability.",
        isFinal: true,
        confidence: 0.95
    ),
    generation: firstGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .activity(.init(isSpeech: false, elapsedMilliseconds: 1_300)),
    generation: firstGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .activity(.init(isSpeech: false, elapsedMilliseconds: 2_200)),
    generation: firstGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .speechEnded,
    generation: firstGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)

print("\n2. Route change ends generation \(firstGeneration.rawValue)")
feed(
    .session(.routeChanged),
    generation: firstGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)

// A restarted platform capture owns a new generation. Its local transcript
// identity may begin at 1 again; generation ownership prevents aliasing.
let secondGeneration = machine.beginGeneration()
_ = machine.receive(.session(.startRequested), generation: secondGeneration)
_ = machine.receive(.session(.captureStarted), generation: secondGeneration)
gate.reset()
print("capture generation: \(secondGeneration.rawValue)")
print("capture after restart: \(machine.state.session)")

print("\n3. New generation opens its own utterance")
feed(
    .activity(.init(isSpeech: true, elapsedMilliseconds: 25)),
    generation: secondGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)

print("\n4. Delayed generation-\(firstGeneration.rawValue) callbacks arrive after generation \(secondGeneration.rawValue) is already active")
let staleTranscript = feed(
    .transcript(text: "stale callback from old capture", isFinal: true, confidence: nil),
    generation: firstGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
let staleEnd = feed(
    .speechEnded,
    generation: firstGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
if staleTranscript.events.isEmpty && staleEnd.events.isEmpty {
    print("stale callbacks rejected: yes")
} else {
    print("stale callbacks rejected: NO")
}

print("\n5. Current generation remains authoritative")
feed(
    .transcript(text: "Fresh utterance", isFinal: true, confidence: 0.9),
    generation: secondGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .speechEnded,
    generation: secondGeneration,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)

print("\nM2 generation-owned adapter pipeline simulation complete.")
