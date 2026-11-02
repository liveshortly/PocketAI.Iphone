# PocketAI iPhone redesign — implementation log

Tracks execution of `iphone-ui-redesign-handoff.md` (T0–T7). One section per stage: completed requirements, files changed, tests run + results, evidence, blockers.

**Scope reality:** This is a multi-session program (26 findings, many P0, across Rust FFI / store / download coordinator / engines / a 5-tab UI redesign, plus 28 acceptance scenarios). Several acceptance checks are **device-gated** (MLX inference, background downloads, Apple Intelligence eligibility, paired-Mac routing) and cannot be verified on the simulator/PreviewCore per §12.3. Those stay explicitly pending with the exact remaining test named. No stage is marked done on compile-only.

---

## T0 — Baseline (in progress)

**Environment:** macOS (Darwin 25.4.0). Build host has Apple Distribution cert (team 4RK6YA795V). Device "Ro" = iPhone 17 Pro (physical, paired). Booted sim target: iPhone 17.

**Repo state at start (23 Oct 2026):**
- `PocketAI.Iphone` git HEAD `d3669fd`, ~18 uncommitted changes (tonight's work: AppModel, ChatView, ChatsListView, DevicesView, ModelsView, OnboardingFlow, RootTabView, SettingsView, SpeechPlayback, project.yml; new: Permissions/, NetworkMonitor.swift, SettingsDestinations.swift, Assets.xcassets, Entitlements/PocketAI-dev.entitlements).
- `PocketAI.Core` git HEAD `090ec4e`, ~21 uncommitted changes (tonight: unload API, RAG vectors, CompositeEngine, NET-14 auth, SyntaxHighlighter, MarkdownTable, set_conversation_model, update_model).
- Parent `getpocketai` is not a git repo.

**Test wiring (F23 recheck):** current `PocketAI.Iphone/project.yml` **already declares** the `PocketAIUITests` (`bundle.ui-testing`) target and wires it via `scheme.testTargets`. UITests files present: ChatFlowUITests, DownloadStateUITests, SettingsFlowUITests, AccessibilityAuditTests, PerfTests. No dedicated unit-test target yet (needed for coordinator/transport tests per §12.3). Version no longer hardcoded 0.2.0 — now CFBundleShortVersionString 1.0 / CFBundleVersion from project.yml (F23 version half addressed).

**Already-landed tonight that overlaps the handoff (verify, don't redo):**
- `set_conversation_model` FFI + `update_model` repo (referenced in §11.3) — exists, built, on device.
- Vision attach-guard (F-adjacent), download live-poll + real byte-delta rate (partial F06/F09 UI), NWPathMonitor (partial F10), honest instruments purge (partial F20), permission primers.
- **Caveat (F04):** a blanket `setConversationModel(selected)` was added to `ChatView.send()` tonight as a hotfix. The handoff §9.1/F04 wants the opposite nuance — default vs per-chat separation, no global overwrite every send. This will be **reworked in T1** (bind-on-unbound only + per-chat picker), not kept as-is.

**Baseline build:** both apps built green tonight against the current tree (iOS sim + macOS). Recorded in prior session logs.

### T0 remaining
- Add a unit-test target for coordinator/transport (§12.3) — pending.
- Capture before screenshots of the reported glitches (empty space, scrolling gear) on device — pending (device capture).

---

## T1 — Identity and read model (in progress)

Target findings: F03, F04, F15, F16, F17, F25 (read side), §9.1 model-selection semantics.

### Changes (landed, built green iOS sim + macOS)
- **F17 — conversation fetch-by-ID:** new Core `get_conversation(id)` FFI (`core.rs`) + repo-backed read; `CoreClient.conversation(id:)` + LiveCore + PreviewCore. ChatView `reload()` now resolves title + bound model by ID instead of page-scanning `conversations(limit:0)` (which missed older chats).
- **F03 — next-turn model:** ChatView `currentModelId` now returns the conversation's bound `model_id` (cached in `@State conversationModelId`, loaded by ID in `reload()`), never the last assistant message, never the global default unless unbound.
- **F04 — no global overwrite:** replaced the blanket `setConversationModel(selected)`-every-send hotfix with bind-on-unbound/invalid only (`isModelUsable` guard). A valid per-chat choice is never overwritten by the global default on send. Self-heals a chat bound to a deleted model by rebinding to the default. _(Proper "unavailable — choose another" + per-chat picker is T5/U8.)_
- **F16 — peer-specific routing:** new `RemoteEngine.peerId(from:)` (decodes `mac:<peer>/<model>`). `LazyRemoteEngine` factory signature changed to `(_ modelId: String?) -> PeerClient?`; `load` resolves the *specific* paired Mac, generate/unload reuse that engine (one active generation, §9.2). AppModel factory resolves peer by encoded id (not `peers().first`); ChatView header label, Pulse location, and reconnect all resolve the specific peer. Updated the `EngineFoundationTests` constructor + kept Mac compiling (Mac doesn't construct LazyRemoteEngine).

### Verification
- `cargo build -p pocket-ffi` ✅; xcframework rebuilt with `getConversation` binding ✅.
- iPhone sim build ✅ (`** BUILD SUCCEEDED **`, T1 first batch). F16 batch + Mac build in progress.
- `swift test` (PocketKit, incl. updated LazyRemoteEngine test) — pending next Core test run.

### F15 — Apple Intelligence (resolution/routing layer; landed, Core compiles)
- `find_manifest` now returns a synthetic built-in manifest for the `apple-intelligence@on-device` sentinel (empty hf_repo/no files, `format: apple-foundation`, `tags: [built-in]`), so selection/send resolve + route to the Apple engine instead of failing `NotFound` (§9.1).
- New `APPLE_INTELLIGENCE_MODEL_ID` const in `core.rs` (must track `AppleFoundationModelsEngine.modelId`).
- Engine order in AppModel's RoutingEngine put **Apple before MLX** so the built-in sentinel can't be intercepted by generic MLX support (§9.1).
- **Still UI (T4/T6):** show Apple as a selectable "Built in" row in the shared picker (no Download/Delete/Pause), onboarding "Try Apple while downloading" actually selecting the Apple route, and availability-reason states (ready / unsupported / not-ready). **Device-gated (A23):** real eligible-iPhone Apple inference + cancel.

### T1 remaining
- F25 (read side) — merge persisted installs into catalog so noncurated installed models show everywhere; enforce chat-capable filter in fallback.
- Summary/aggregate reads for Home/history (§9.4) — overlaps T4.
- **Device-gated:** local→Mac / Mac→local / second-peer routing (A05/A06) need a paired Mac; recorded pending.

---

## T2 — Transfers and privacy (in progress)

Target findings: F06, F07, F10 (+ F08 relaunch, device-gated).

### Changes (coordinator rewrite — ModelDownloadCoordinator.swift)
- **F06 pause requeue:** pause/offline now re-insert the in-flight file at the FRONT of `queued` and keep its resume data, and add the model to a `paused` set that `fillSlots` skips. Resume clears it and continues from the resume data. (Before: the active file was dropped from `active` and never requeued, so Resume did nothing.)
- **F07 aggregate bytes:** coordinator tracks `completedBytes` (finished files) + per-task `activeBytes` and reports the SUM to Core; a single file's progress no longer overwrites the model total.
- **F07 error path:** new `didCompleteWithError` — releases the slot, stores resume data, requeues the file for Retry, marks `failed:network`, refills other models. No tight retry loop. `active`-map membership is the single authority, so a paused/cancelled task's late error callback is ignored (no double-handling).
- **F10 offline enforcement:** `start`/`fillSlots`/`resume` gate on `core.isOffline()`; Offline-mode pause is a distinct `paused:offline` state; turning Offline off does not auto-resume (§8.6). New Core `set_download_state(id, state)` FFI (never marks `installed` — only `verify_and_commit` does). A `verifying` state shows before commit.

### Verification
- `cargo build -p pocket-ffi` OK. xcframework rebuild + app builds in progress.
- **Pending (test harness):** real two-file transfer / pause-resume-cancel / aggregate / error states need a local HTTP fixture server per §12.3 (PreviewCore cannot validate the coordinator). A07/A08/A09/A12 pending.
- **Device-gated (F08):** background suspension + force-quit relaunch recovery (re-attach background URLSession, reconstruct queued/plans on launch) — NOT yet implemented; in-memory state still does not survive cold start. A11 pending on device.

---

## T3 — Chat behavior (in progress)

Target findings: F11, F12, F13, F17(Rust half), F05(pending).

### Changes (landed; Core tests 50+24 pass)
- **F11 true cancellation:** Core keeps a `conversation_id -> request_id` map (`active_requests`), set around `generate` and cleared on every terminal path; new `cancel_conversation(id)` FFI reaches `engine.cancel(request_id)`. MLX already honors it (`cancelTask` → `Task.isCancelled` → `.cancelled`). CoreClient `cancelConversation` + LiveCore `onTermination`/method + `ChatView.stop()` call it. (Apple cancel still empty — device-only; real mid-generation interruption is device-gated, A18.)
- **F12 safe retry:** new Core `regenerate(conversation_id)` drops the trailing assistant message and re-runs from existing history via a shared `generate_reply` helper (extracted from `send`) — no duplicated user turn, never the assistant text as prompt. CoreClient/LiveCore/PreviewCore `regenerate` stream; ChatView factored `consumeStream`, added `regenerateLastTurn`, repointed all 4 retry sites (assistant row, error card, errorCard button, reconnect) off the old copy-text-to-composer path. Removed dead `retry(after:)`.
- **F13 parts persistence:** Rust `parts_to_content_json` / `extract_parts` (backward-compatible with old `{"text":...}` rows) — user messages persist full parts; `messages()` reconstructs them; history fed to the engine now carries image parts (was flattened to text). 
- **F17 (Rust half):** `send`/`generate_reply` resolve the conversation by ID via `ConversationsRepo.get`, not the 50-row `list_conversations` page-scan.

### Verification
- `cargo test -p pocket-ffi -p pocket-store` OK (50+24). xcframework rebuild + app builds in progress.
- **Device-gated:** real MLX mid-generation Stop (A18), image actually reaching a VLM end-to-end (A19) — sim can't run MLX.
- **Remaining T3:** F05 title policy (first user msg + first answer, atomic manual-rename guard, bounded/cancelable) — pending. Full GenerateStats persistence (F20 part). Project-context injection + File/Project doc (F14) — pending (overlaps §9.3).

---

## T4/T5/T6 — UI (parallel)

Shared `Sources/Shared/ModelPickerView.swift` created (scope default/conversation; On this iPhone + Apple Intelligence built-in + paired Macs; chat-capable only; §5.3/§11.1) — builds green.

### T5 — Chat & history UI (me; landed, pending combined build)
- **Header (U1/U2/U8):** `.principal` toolbar now has `PocketMarkView` (animates while answering, tap → Pulse) left of the title, with a tappable "Model · Location ▾" subtitle opening `ModelPickerView(scope: .conversation)`. Removed the full-width bottom PulseStrip (§5.1). `bindModel` persists the per-chat choice via `setConversationModel` (never the global default). "Stop to switch models" alert while generating (§5.3).
- **F21:** swipe-Delete now routes through a confirmation dialog in ChatsListView before `deleteConversation`.
- Preserves all T3 logic (regenerate/consumeStream/cancellation/F16 peer labels).

### T4 — shell + Home (agent) / T6 — Models + Settings (agent)
Running in parallel; file-disjoint (RootTabView/Home/AppModel/intents vs Models/Settings/Onboarding). Combined build + reconcile when both land.

### Integration (all stages) — combined build GREEN on sim
- T4 (RootTabView 5-tab shell + HomeView + AppNavigator nav + intents), T5 (chat header/picker/F21), T6 (Models filters/rings/live-detail + Settings default-picker/storage/version + Onboarding default) + Core F25 (merge installed off-catalog models) + `paused:offline`→Paused mapping — all compile together.
- ChatView body split into `chatScaffold` + `body` to fix a SwiftUI type-check timeout; nav state isolated in `AppNavigator` (not piled on AppModel) for the same reason.
- ChatsListView consumes `nav.pendingOpenConversationId` (Home/intent → open exact chat, F26).

### Still open after this pass (honest)
- **F05** title policy (first user msg + answer, atomic manual-rename guard) — pending.
- **F14** project-context injection + File/Project doc wiring — pending.
- **F08** download relaunch recovery (background session re-attach) — pending (device).
- **Device-gated:** MLX inference, real Stop mid-generation (A18), background/relaunch downloads (A11), Apple eligibility (A23), paired-Mac routing (A05/A06) — can't verify on sim/PreviewCore.
- **Test harness:** local HTTP fixture server for real transport tests (§12.3) — not built.

## 2026-10-24 — GGUF + reliability + cozy Models round (device build 1.0 (7), installed to "Ro")

Research verdict: GGUF bindings ARE shipped (pocket-engine bundles llama.cpp/Metal;
real-inference test passes). What broke GGUF chat on device:

- Core: fresh 2–2.5 GB model copy loaded per message (handles never reused) → OOM by turn 2-3.
  Fixed with load_or_reuse + new test. Stop now cancels on the owning engine (was Swift-router-only).
  Effective context = min(catalog, platform cap 4096 iOS / 8192 Mac) for both load + truncation.
  on_memory_warning drains handles (iPhone now forwards didReceiveMemoryWarning).
  Decode drop-order UAF fixed; ImageRef stripped from history for non-vision models; double-BOS fixed;
  cancelled replies persist "cancelled" (no title gen); duplicate in-flight sends rejected;
  ttft includes prefill; F25 merge now surfaces off-catalog rows in any state.
- Entitlements: dev file was empty — added increased-memory-limit + extended-virtual-addressing
  (signed + verified on device build).
- Downloads: relaunch verify (no stranded "downloading"), HTTP 200/206 required, verify errors
  surface failed:* + requeue, resume re-plans after relaunch, sha256 off delegate queue,
  background-session relaunch handler in PocketAIApp.
- iPhone app: Apple Intelligence counts as usable (no silent model switch); Mac models in picker
  (ModelPickerView.reloadRemote); onboarding suggestions actually send (nav.startNewChat);
  chat Delete dismisses; stop→retry stream race fixed (stream id); catalog cached per reload
  (no per-token re-parse); hub search async + spinner + results persist; Won't-fit can't download;
  measured-vs-est speed label honest; real thermal state + egress count in Pulse; Siri intents show
  real error + archived; pairing cancellable + 2-min timeout + no fake "Connected" copy; preview-core
  fake pairing gated to -PocketPreviewCore; project delete confirmation; 44pt chips; dead File/Project
  doc attach options removed; failed onboarding download gets Retry/back + honest sizes (no 18MB/s).
- Models page cozy pass: ModelRow 4 lines → 2 (license/speed detail → sheet), small capsule action,
  hero flattened (headline + one meta line), compact transfer rows, Devices "Browse models on this
  Mac…" now opens the real On-your-Mac segment (placeholder + dead row removed).
- project.yml: restored lean signed variant (team 4RK6YA795V, PocketAI-dev entitlements);
  full variant backed up in session scratchpad.

Verified: cargo workspace green (incl. new reuse/memory-warning test + real GGUF inference),
PocketKit swift build green, device build signed with memory entitlements, installed to "Ro".
Pending user verification on device before TestFlight build 8.

## 2026-10-24 — UX round 2 + reasoning + Mac overhaul (TestFlight build 8 live)

- Chat UX: pinned-to-latest scrolling (only a user drag unpins; overlay jump pill),
  centered delete alerts everywhere (+ chat-menu delete confirmation), rows are real
  NavigationLinks (single-tap open), header title block opens per-chat model picker
  (+ "Change model" in ••• menu), instant local user echo + immediate reply bubble,
  multi-select delete (long-press → Select Chats, Select All, bottom-bar Delete).
- Reasoning: core AccumulatingSink splits <think>…</think> into Message.reasoning
  for every engine; persisted in the reasoning column; titles can't contain think-text.
  UI: live "Thinking…" spinner pane (expandable mid-stream, scrollable, capped 180pt),
  collapses to "Thought for a moment". 51 ffi tests green.
- TestFlight: build 1.0 (8) uploaded, VALID, compliance auto-cleared, internal testers.
- Mac app overhaul (agent, 20 items all done): Release link fix (ARCHS arm64),
  persisted current model, ⌘N fix, instant echo/stop/regenerate/per-chat model,
  Devices lists devices() not peers(), LAN toggle restarts server, pairing_identity()
  FFI getter (no secret rotation), approval prompts from any tab, https samples,
  license key persisted in keychain (DEBUG always Pro), real download totals,
  read-write export entitlement. Installed to /Applications; iPhone rebuilt green
  against regenerated bindings and reinstalled.
