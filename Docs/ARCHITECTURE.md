# Architecture

LiveState is a pure Swift domain layer. It does not depend on SwiftUI, AVFoundation, Vision, Speech, or a specific model provider.

## Unidirectional flow

Event → Reducer → new EncounterState + Effects → effect runner/service → new Event

Reducers remain deterministic. Network, model, audio, and camera work belong outside them.

## Policy vs language

Policy decides what should happen next. A future language model decides how the counterpart says it. Model output is treated as untrusted input and must be validated before influencing state.

## Checkpoints and branches

A checkpoint captures simulation state before a meaningful divergence. Restoring it preserves prior history and creates a new branch identity. The original path remains intact.

## Inference boundary

The product may use observable signals such as timing, interruptions, speech duration, framing, and movement. It must not claim to infer truthfulness, intelligence, anxiety, or mental state from camera/audio signals.
