# Claude Goal: PocketAI iPhone redesign

Paste the prompt below into Claude's Goal from the getpocketai workspace. The full specification is [iphone-ui-redesign-handoff.md](iphone-ui-redesign-handoff.md).

---

Implement the PocketAI iPhone redesign and reliability plan in:

PocketAI.Iphone/docs/iphone-ui-redesign-handoff.md

Read that entire document and the applicable repository instructions before editing. Treat U1–U8, the behavior contracts, and the acceptance matrix as the required scope. The deliverable is a working iPhone app with evidence, not another plan or a PreviewCore-only demonstration.

The target experience is five stable tabs (Home, Chats, Models, Mac, Settings), a useful Home dashboard, a chat header with the animated PocketAI mark to the left of an automatic title plus visible model/location, a clearly highlighted composer, per-chat model switching, compact capability-filtered model lists with working download rings and controls, and Settings with a real default-model picker including Apple Intelligence.

Fix the underlying defects documented in the handoff: model selection/routing, download lifecycle and offline behavior, true engine cancellation, correct retry, attachment persistence, title races, older-chat lookup, real statistics, data recovery, and the other required findings. Reuse the existing SwiftUI/PocketUI/PocketKit/Rust architecture and Ember theme. Preserve existing chats, model files, pairing credentials, manual titles, and uncommitted work. Do not redesign the Mac UI.

Start with T0 and progress through T1–T7 in dependency order. The workspace contains separate repositories and existing edits; inspect each relevant Git status/diff before changing it. Recheck the source-review findings against the current tree because files may have changed since the audit. Fix shared causes once, update every affected caller/fixture, and regenerate FFI/XcodeGen outputs using the existing scripts. Follow the established L0 review requirement for FFI changes.

Keep a concise progress/evidence checklist at PocketAI.Iphone/docs/iphone-redesign-implementation-log.md. For each stage, record completed requirements, files changed, tests run and results, screenshots, and remaining blockers. Make routine implementation choices yourself within this specification; do not stop after each stage to ask whether to continue.

Use simulator/PreviewCore for UI and deterministic fixtures, real small-file transport tests for downloads, and an eligible physical iPhone/paired Mac for behavior that requires hardware. Confirm tests are actually wired into a testable scheme. Never treat a simulated transfer or UI-only Stop as proof of the production feature.

Complete all feasible implementation and required checks. Keep any unavailable-device validation explicitly pending; report what is missing and the exact remaining test. Do not claim the goal is complete while required behavior remains broken or unverified. Do not reset user data, publish a build, change signing/entitlements, or introduce unrelated features as part of this goal.

Finish with a short report: completed requirements, validation performed, before/after evidence, unresolved items, and material compatibility or data risks.
