# Offscript

**Get good at what happens next.**

Offscript is an experimental native iOS social-simulation product for practicing unpredictable real-world conversations.

**Status:** Milestone 1 — LiveState Playground. The product name is a working name pending formal clearance.

## Core idea

Most AI practice tools can be approximated by a role-play prompt. Offscript is engine-first:

- persistent simulation state;
- objectives and policy separated from generated dialogue;
- evidence-backed state transitions;
- checkpoints that restore prior state;
- alternate branches without destroying the original attempt;
- later: realtime silence, interruption, observable signals, and Duo-specific experiences.

## Milestone 1

Typed input deliberately proves the core loop before microphone, camera, TTS, cloud models, or Duo UI:

Event → Reducer → State → Effect → Evaluation → Policy → Checkpoint → Branch

Run:

    swift test
    swift run LiveStatePlayground

## Architecture rule

**AI never owns application truth.**

Models may interpret, classify, reason, and generate language. LiveState owns the simulation.

See Docs/ARCHITECTURE.md and Docs/ROADMAP.md.
