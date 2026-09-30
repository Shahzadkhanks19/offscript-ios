# M2 Realtime Voice Adapter Contract

LiveState stays framework-independent. Apple frameworks belong in a future iOS
adapter target; they must not leak into the authoritative simulation engine.

## Capture adapter

An Apple capture adapter conforms to `VoiceInputService` and translates
AVFoundation/Speech observations into `VoiceCaptureEvent`.

It must:

- emit raw activity observations rather than deciding semantic barge-in or
  meaningful silence;
- normalize ASR updates into complete best-known `VoiceTranscript` snapshots;
- keep `utteranceID` stable for one physical utterance and change it at the
  next speech boundary;
- increase `revision` monotonically within that utterance;
- use a monotonic clock for activity timing;
- make `start()` and `stop()` safe across cancellation, interruption,
  permission failure, route changes, and repeated teardown;
- finish or fail its event stream when capture ends unexpectedly.

The adapter must not mutate EncounterState or infer counterpart/user intent.

## Playback adapter

An Apple speech adapter conforms to `CounterpartSpeechService`.

It must:

- associate every transport request with the supplied `SpeechPlaybackID`;
- make `stop(playbackID:)` cancel only the requested playback when an ID is
  supplied;
- tolerate repeated stops and `stop(nil)`;
- return from `speak` only when that playback finishes or throws;
- surface genuine transport failures, while allowing coordinator generation
  ownership to classify superseded playback as expected cancellation.

## Ownership

`VoiceSessionCoordinator` remains the owner of:

- semantic turn boundaries;
- meaningful silence and barge-in policy;
- playback supersession;
- LiveState event emission;
- session generations and stale-callback rejection.

The platform adapter owns hardware/framework mechanics only.

## First macOS/Xcode implementation

When Xcode is available, add a separate Apple adapter target rather than adding
conditional Apple imports to LiveState. The first vertical slice is:

1. request microphone/speech permissions;
2. configure an AVAudioSession for two-way spoken interaction;
3. capture microphone audio;
4. stream transcription snapshots;
5. derive raw voice-activity observations from capture measurements;
6. implement interruptible counterpart playback;
7. wire both adapters into `VoiceSessionCoordinator`;
8. validate interruption, route-change, background/foreground, and teardown
   behavior on simulator/device where supported.

Windows continues to compile and test LiveState without Apple frameworks.
