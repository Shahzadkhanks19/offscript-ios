import LiveState

func describe(_ event: VoiceCaptureEvent) -> String {
    switch event {
    case let .activity(observation):
        return "activity: \(observation)"
    case let .transcript(transcript):
        return "transcript[u=\(transcript.utteranceID.map(String.init) ?? "nil"), r=\(transcript.revision), final=\(transcript.isFinal)]: \(transcript.text)"
    }
}

func feed(
    _ input: VoiceCaptureAdapterInput,
    into machine: inout VoiceCaptureAdapterMachine,
    gate: inout VoiceActivityGate,
    counterpartIsSpeaking: Bool
) {
    let output = machine.receive(input)
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
}

print("Offscript — M2 Realtime Voice Playground")
print("Platform-neutral simulation of capture -> VAD -> transcript boundaries\n")

var machine = VoiceCaptureAdapterMachine()
var gate = VoiceActivityGate()

_ = machine.receive(.session(.startRequested))
_ = machine.receive(.session(.captureStarted))
print("capture: \(machine.state.session)\n")

print("1. User begins while Maya is speaking")
feed(
    .activity(.init(isSpeech: true, elapsedMilliseconds: 1_000)),
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: true
)
feed(
    .activity(.init(isSpeech: true, elapsedMilliseconds: 1_180)),
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
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .activity(.init(isSpeech: false, elapsedMilliseconds: 1_300)),
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .activity(.init(isSpeech: false, elapsedMilliseconds: 2_200)),
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .speechEnded,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)

print("\n2. Route change invalidates the old capture run")
feed(
    .session(.routeChanged),
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .transcript(text: "stale callback", isFinal: true, confidence: nil),
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
_ = machine.receive(.session(.recoverySucceeded))
gate.reset()
print("capture after recovery: \(machine.state.session)")

print("\n3. Fresh speech after recovery")
feed(
    .activity(.init(isSpeech: true, elapsedMilliseconds: 25)),
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .transcript(text: "Fresh utterance", isFinal: true, confidence: 0.9),
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)
feed(
    .speechEnded,
    into: &machine,
    gate: &gate,
    counterpartIsSpeaking: false
)

print("\nM2 adapter pipeline simulation complete.")
