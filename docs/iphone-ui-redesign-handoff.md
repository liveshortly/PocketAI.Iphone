# PocketAI iPhone redesign and reliability handoff

Date: 23 October 2026  
Status: Implementation plan; no application changes made by this review.  
Audience: Claude implementing the next iPhone release.

## 1. Outcome and boundaries

Make PocketAI's iPhone experience clear, compact, responsive, and dependable: users can find a model, download it with working controls, understand where it runs, start a chat, change its model, and return to useful history.

All eight owner requests below are required. Fix the underlying behavior as well as its presentation. A working PreviewCore demonstration alone does not satisfy a real download, cancellation, inference, or persistence requirement.

- Redesign the iPhone app. Shared Core, PocketKit, PocketUI, and engine changes are allowed where necessary for the iPhone behavior. Keep Mac consumers compiling and functioning; do not redesign Mac.
- Retain the existing Ember accent, PocketAI mark, light/dark surfaces, SF typography, and PocketUI tokens.
- Support the current iOS 18 deployment baseline, with availability checks for newer APIs. Retain current iPhone-only, portrait distribution settings unless separately changed by the owner.
- Preserve chats, titles, attachments, projects, installed weights, device credentials, and manual model choices. Do not reset data to make the new UI work.
- Reuse existing components, repositories, engines, and tests. Avoid a new design framework, analytics service, inference backend, or generic navigation architecture.
- This document supersedes conflicting iPhone layout details in the older design spec, specifically the four-tab shell and bottom Pulse strip. Existing architecture, privacy boundaries, and brand tokens still apply.
- App Store/TestFlight publication, pricing, entitlements, Share Extension restoration, and Mac visual changes are outside this handoff.

### Evidence and limits

This is a source review of the working trees, not a completed device usability test. The owner's empty-space and scrolling-icon observations are requirements; their precise appearance still needs a before/after capture on an iPhone.

Reviewed repositories: PocketAI.Iphone at HEAD d3669fd and PocketAI.Core at HEAD 090ec4e, both with substantial existing uncommitted work. The parent getpocketai directory is not a Git repository. Re-read current diffs before editing; do not discard or overwrite prior work. Line numbers below describe the reviewed working tree and may move.

Read [iPhone instructions](../CLAUDE.md), [Core instructions](../../PocketAI.Core/CLAUDE.md), [existing design system](../../strategy/02-design-system.md), and [accessibility checklist](accessibility-checklist.md). Core's instructions require L0 review for FFI changes: record that review requirement in the implementation handoff and use the project's established review process.

## 2. Owner requirements and their acceptance targets

| ID | Request | Required result | Specification |
|---|---|---|---|
| U1 | Model-generated chat name; move Ready to the top; animate while answering; highlight composer | Title reflects the first exchange, the PocketAI state mark is left of it, model/location remain visible, composer has a clear focus treatment | §§5, 9 |
| U2 | Model name and on-device/connected-system identity in chats | Header, chat rows, and mixed-model replies distinguish the actual model and execution location | §§5, 9 |
| U3 | Home button/dashboard with downloaded models and useful statistics | Permanent Home tab, locally computed activity, installed models, active downloads, recent chats | §4 |
| U4 | Recover wasted space in Models | Remove fixed bottom reservation; content ends at the actual safe area; compact useful rows | §6 |
| U5 | Quick Voice, Vision, Text filters and better Fits-only layout | Capability chips, compact Fits chip, responsive results and honest empty states | §6 |
| U6 | Circular download progress on main model list; working pause and stop | Same live state in list/detail/Home/onboarding; real Pause, Resume, Cancel and Retry behavior | §§6, 8 |
| U7 | Fix Settings whitespace/appearing gear; select default model including Apple | Stable tabs, safe-area layout, shared model picker, genuine Apple availability/routing | §§3, 7, 9 |
| U8 | Change models inside each chat | Tappable header subtitle; persisted per-chat choice, safe switching, preserved history | §§5, 9 |

## 3. Navigation and visual foundation

Use five native tabs in this order: **Home · Chats · Models · Mac · Settings**. Keep the existing Mac entry rather than burying an established feature. Home is the initial destination after onboarding; preserve explicit deep links and an already-open chat.

- Keep the tab bar expanded on scrolling screens. Remove the current global on-scroll minimization. This is the first candidate fix for the reported isolated Settings gear; reproduce it before claiming the cause is proven.
- Use one NavigationStack per tab. Home's New chat/Recent chat actions select the Chats tab and open the exact conversation. Manage models opens Models with the appropriate segment. Avoid duplicate stacks displaying the same chat.
- Preserve each tab's search/filter/scroll state during ordinary tab changes. Changing tabs must not change the selected model or restart transfers.
- Hide the tab bar inside a pushed chat detail to protect composer space, with a standard Back action to Chats. Home stays one further tap away; no extra floating Home control inside the conversation.
- Use actual safe-area insets. Remove the Models list's 110-point and Settings list's 80-point bottom padding. Do not replace them with other guessed heights.
- Use existing 16-point iPhone gutters, card/field radii, text styles, and accent tokens. A short list may naturally leave space; do not add filler cards just to cover it.
- Loading, empty, error, unavailable, and filtered-empty screens each need useful text and one appropriate action.

Conceptual hierarchy, not fixed pixel dimensions:

~~~
HOME                     CHAT
PocketAI                 < Chats   [mark] Plan a weekend trip     …
Ready on this iPhone                Qwen · On this iPhone v
[New chat: Qwen v]
[Chats saved] [Most used]           Conversation
Downloaded models                 [Jump to latest, if needed]
  Qwen                  Chat
  Vision model          Chat      [attachment preview, if any]
Downloads in progress             [+ Message…             ↑/■]
Recent chats
Home Chats Models Mac Settings
~~~

At accessibility text sizes, allow the chat header subtitle to occupy a separate row below navigation controls. Do not shrink the title or hide the model/location to keep a one-line toolbar.

## 4. Home specification

Create a small Home screen using existing StatTile, model rows, and list/card styles.

Content order:

1. **Ready to chat:** effective default model and execution location; New chat primary action. If unavailable, say why and offer Choose model. An available Apple model can be used without a PocketAI-managed download.
2. **Two activity tiles:** Chats on this iPhone and Most used model. Both computed from saved records on this installation.
3. **Downloaded models:** compact rows for every installed local model, with capability, size, and relevant action. Show up to three initially, with Show all expanding the list in place and Manage opening Models. Text/vision rows can start chat; speech/image rows open their supported workflow or explain unavailability.
4. **Active downloads:** progress and controls using the same data as Models. Omit the section when empty.
5. **Recent chats:** five most recently active, nonarchived conversations, with title, preview, model/location, and timestamp; See all opens Chats.
6. A compact **Mac status** row when paired, linking to the existing Devices screen.

Metric definitions:

| Metric | Definition |
|---|---|
| Chats on this iPhone | All nondeleted conversations stored in this installation with at least one user message, including archived chats and chats served by a Mac. It measures saved chats, not local inference only. |
| Most used model | Model with the most completed assistant replies across those chats. Exclude title-generation requests, failed/stopped attempts, and previews. Break ties by latest completed reply. Display its location when needed to distinguish routes. |
| Downloaded models | Installed, verified local artifacts. Exclude partial downloads, remote models, and Apple's system-managed model. Show Apple separately as Built in when available. |
| Model storage | Actual local bytes for installed artifacts; disclose partial-download storage separately. Do not use estimated runtime RAM as storage. |

No history means zero chats and “No replies yet,” not invented activity. Use aggregate/local summary queries; do not load every transcript on the main thread to render Home. Counts must still be correct with more than 50 conversations. Refresh after chat completion/deletion/archive, download completion/deletion, model changes, and foregrounding.

Acceptance: every installed model is reachable from Home, all tiles agree with seeded records, and tapping a recent chat opens that exact ID with its draft/history intact.

## 5. Chat and history specification

### 5.1 Header and execution status

- Place the existing compact PocketMarkView immediately left of the chat title.
- Under the title, always show a tappable subtitle: **Qwen3 4B · On this iPhone ▾**, **Qwen · Rohit's Mac ▾**, or **Apple Intelligence · On this iPhone ▾**. Use catalog display names; raw IDs are a fallback only.
- The header describes the model selected for the next turn, or the captured route of the currently running turn. Never infer next-turn identity from the latest assistant message.
- The mark represents real state: Choose a model, Ready, Loading, Answering, Stopping, Interrupted, or Error. Use the existing Ember working/loading animation; stop it on completion/cancellation/error. Reduce Motion uses a static mark plus text.
- A tap on the status mark opens Pulse details. Remove the full-width bottom Ready/Pulse strip from the iPhone chat.
- Show connection failures beside the relevant remote route. Offer explicit Switch to an on-device model; never silently reroute private content.
- Keep the overflow menu for Rename, Export, Archive, Delete, and Speak replies. Prefer moving the redundant persistent speaker button into this menu to make space for the title.
- Display model and location on each assistant turn when the route changes, with complete provenance available in its details/export. Older replies retain their original model even after a switch.
- Chat-list and Home recent-chat rows show the conversation's selected model/location for its next turn. An unbound conversation says Choose a model; historical reply details retain the model actually used.

### 5.2 Automatic titles

Reuse Core's generate_title path; it already exists. Correct its input, timing, and update rules:

1. Show New chat until the first user input is saved.
2. Immediately use a short first-message fallback so lists are understandable.
3. After the first successful answer, ask the same model/route for a short title based on the **first user message and first assistant answer**, with a bounded input budget. For an image-only prompt, include the answer and a neutral attachment descriptor.
4. Target 3–6 words for languages with spaces; cap display length at 64 characters without breaking Unicode. Normalize quotes/newlines and fall back on empty/refusal/invalid output.
5. Keep the title request out of the visible transcript, answer statistics, dashboard counts, and auto-speech. Complete the visible answer before title generation finishes; the next user turn must take precedence over optional title work. Bound/cancel title work through the existing inference scheduling path so it cannot compete unsafely for the same engine or block the next reply indefinitely.
6. Persist once. Apply automatic output only if the conversation still exists, its first exchange still matches, and the user has not renamed it. Use a small persisted title-origin/pending marker or equivalent atomic guard; do not guess manual intent from the title text.
7. Update the open header, Home, and Chats without a manual refresh. Do not regenerate on every reopen or every model switch.

Acceptance: a first message about travel produces a relevant title; a manually entered title wins a race against automatic generation; title failure leaves the reply usable; reopening keeps the title.

### 5.3 Per-chat model picker

Use the same picker for Settings/default selection, Home, and chat selection, with the scope explicit in its heading.

- Sections: On this iPhone; Apple Intelligence; named paired Mac devices.
- Include only chat-capable models as selectable chat targets. Voice transcription, speech playback, image generation, and embedding models are not chat choices.
- Show name, location, capabilities, availability/fit, and selection checkmark. Provide Manage models for downloads; do not initiate large downloads just by tapping a model row in this picker.
- From a chat, commit the model ID to that conversation, preserve history and the draft, and update header/composer capabilities immediately. Do not change the global default.
- While generating, explain “Stop the reply to switch models.” Stop and switch must cancel the old request and wait for cancellation before starting anything new.
- Revalidate pending attachments and context limits when switching. Explain incompatibility and retain the attachment until the user removes it or selects a compatible model.
- If a selected model was deleted or a Mac became unreachable, retain the intended choice and show an actionable unavailable state. Do not quietly use a different model.

### 5.4 Composer and transcript

- Anchor the composer with safeAreaInset at the bottom. Give the field a solid/raised readable surface, existing field radius, subtle resting border, and Ember focus border or soft glow. Respect high contrast and reduced transparency.
- Grow from one to six lines without clipping. Whitespace-only input cannot send; a valid attachment can send without text.
- Send becomes Stop during generation. Add a code-level guard against double submission, not just a visual disabled state.
- Keep draft text and pending attachments per conversation across navigation and ordinary interruptions. Do not clear them before send has been accepted; a failed send remains recoverable.
- Use actual attachment/capability checks for Photo, Camera, File, and Project doc. A visible enabled action must work. Wire File/Project doc through existing extraction/project services with progress and errors.
- Persist attachment files in app-managed storage and full message parts, not temporary references that vanish after relaunch. Removing an unsent attachment cleans its file; deleting a chat cleans only its owned files.
- Preserve scroll position while reading earlier messages. Auto-follow only when already at bottom; offer Jump to latest otherwise. Streaming should not recreate the whole transcript.
- Retry means retry the selected user turn, preserving its attachments and relevant context. It must not send the assistant's answer as user input or duplicate the user turn.
- For a retry of an earlier turn, use a clearly named Retry in new chat action with context through that user turn, preserving the original conversation; do not rewrite later history implicitly.
- Preserve partial answers on Stop, error, or interruption, with a clear status. Reopening a killed session must not show an endless spinner.
- Confirm chat deletion or provide real undo; dismiss a successfully deleted open chat. Archive has a visible Archived view and Restore action.
- Distinguish no chats from no search results. Keep search reachable with zero matches. New chat and title changes refresh history immediately.

## 6. Models specification

### 6.1 Layout and discovery

Keep the familiar segments **On this iPhone · Browse · On your Mac**; show the remote segment when paired. Prefer On this iPhone initially when something is installed/in progress, otherwise Browse.

Directly below, place a compact horizontally scrolling filter row:

~~~
[All] [Text] [Vision] [Voice] [Images]   [Fits only ✓]
Search models…

Downloads (when active)
  Qwen3 4B                 (ring 42%) [Pause] [Cancel]
  0.9 / 2.1 GB · 12 MB/s · about 2 min

Available models / Installed models
  Model name                    [Get / Chat]
  Text + Vision · Runs well · 2.1 GB
~~~

- One capability filter selected at a time; combine it with search and Fits only. Text includes vision models that also support text; Vision means image understanding; Images means image generation; Voice means speech-to-text or text-to-speech, labeled separately.
- Keep Fits only compact rather than a full-width switch row. Default it on in Browse. Apply it against the device that will run the model, including Mac fit for remote entries.
- Fits must mean usable by a shipped engine as well as fitting memory/storage. Unsupported runtimes should never appear runnable just because weights fit RAM.
- Manage installed/active downloads independently of browsing filters so a filter cannot hide transfer controls. Preserve filter state across tab changes.
- Add a lightweight sort menu: Recommended, Smallest download, Name. Avoid extra filter rows until necessary.
- Keep at most one compact recommendation while browsing unfiltered results. Remove it during search or capability filtering; avoid duplicate prominence for the same entry.
- Use a compact row: display name, capability/family, fit explanation, real download/disk size, primary action. Quantization, full license, context, benchmark details, and source link belong in details.
- Empty result copy names the active query/filter and offers Clear filters. Do not label a filtered list “No models on this iPhone.”
- Search the local catalog immediately. Network search stays explicitly user initiated, has loading/error/cancel states, and runs off the main thread. Ignore stale results when the query changes.
- Use one merged catalog/installation source so noncurated installed models remain visible in Home, Models, Storage, and pickers.

### 6.2 Downloads in rows and details

- Show a determinate Ember ring and accessible percent for known totals, including on the main catalog row. Unknown totals use an indeterminate state; do not invent a percentage.
- Tapping Pause/Resume/Cancel must not also open details. Controls have distinct hit targets, labels, and disabled/pending states.
- Pause retains partial bytes; Resume continues them when possible; **Cancel download** stops and discards only that transfer's partial data after confirmation. Keep an existing verified installation intact.
- Queued, downloading, paused by user, waiting for network, paused by Offline mode, verifying, installed, and failed all need explicit presentation. The coordinator may store pause reason separately from ModelState to avoid unnecessarily expanding the shared enum.
- During verification show Checking files, not an active download or Ready. Expose only controls the implementation can honor during verification.
- Resolve details from the selected model ID on each update, rather than capturing an old CatalogEntry. Row, detail, Home, and onboarding must agree without closing/reopening sheets.
- Use plan.totalBytes or summed manifest file sizes for progress totals. Runtime memory estimates are not transfer sizes.
- Derive speed from measured byte/time deltas; label ETA as approximate and omit speed/ETA while paused, stalled, or unknown. Clamp progress and guard against invalid/zero totals.
- An installed text/vision model has Chat and secondary Set as default actions. “In use” is reserved for a genuinely loaded/running model; selection alone is “Default” or “Selected.”
- Model deletion explains which default/chats reference it and clears invalid default eligibility only after successful deletion. Historical messages remain available.

Acceptance: a download started in Browse remains controllable from On this iPhone, detail, and Home; pause/resume/cancel changes real transfer behavior; the final row says Installed only after verification.

## 7. Settings specification

Use a native grouped list with these compact sections:

1. **Models:** Default chat model with current value; Storage used with actual value; Engine availability as secondary information.
2. **Voice:** Speak replies; Speech-to-text availability; Text-to-speech voice and preview.
3. **Privacy:** Offline mode; Network Proof; existing diagnostic report controls.
4. **Mac & devices:** current paired-device status and access to the existing pairing screen.
5. **About:** version and build from the installed bundle, licenses/help entries that actually exist.

Remove guessed bottom padding. Keep the gear in the permanent tab bar, with no separate floating Settings affordance. Test scrolling with both large and small navigation titles before choosing a consistent style.

Default chat model opens the shared picker, including Apple and eligible paired-Mac models. Its explanation is literal: “Used for new chats. Existing chats keep their selected model.” Changing Settings must not silently overwrite an existing chat on Send.

Apple Intelligence behavior:

- Use the existing AppleFoundationModelsEngine sentinel identity, with a real path through catalog/resolution, readiness, selection, and inference.
- Show ready, not enabled, unsupported device/OS, model not ready, and unknown unavailable reasons as appropriate. Recheck when returning from system Settings.
- Present it as a built-in on-device model. PocketAI cannot provide Download/Delete/Pause controls for Apple's system-managed weights.
- An unavailable Apple model must not lead to a PocketAI Pro error. Do not offer a switch that claims to enable Apple Intelligence globally inside PocketAI.
- Guard all newer APIs against the deployment baseline and installed SDK. Apple's availability API is the source of truth, rather than a hand-maintained phone list. See [Apple SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) and [model-not-ready reasons](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason/modelnotready).

Acceptance: selecting Apple in Settings produces a real local reply on an eligible device; unsupported devices show a specific reason; defaults survive relaunch; Settings values reflect changes elsewhere.

## 8. Download correctness contract

Repair the existing ModelDownloadCoordinator and Core persistence. Do not create another independent downloader for Home or model details.

| State | Primary action | Secondary action | Required behavior |
|---|---|---|---|
| Available | Download, if supported and eligible | Details | Validate files, storage, network policy and fit before starting |
| Queued | Cancel | Details | No duplicate tasks if tapped repeatedly; count toward transfer UI |
| Downloading | Pause | Cancel download | Record aggregate progress and stop scheduling new files when pausing |
| Pausing | Disabled pending control | Details | Reconcile asynchronous cancellation/resume-data callbacks |
| Paused by user | Resume | Cancel download | Remain paused after reconnect, relaunch, and tab changes |
| Waiting for network | Retry/automatic recovery | Cancel download | Resume only if policy allows and the user did not pause |
| Paused by Offline mode | Explain how to turn it off | Cancel download | Turning Offline mode off does not automatically resume |
| Verifying | Checking files | Details | No model use until all required files verify and commit |
| Failed | Retry | Cancel/clear partial transfer | Preserve error reason; keep safe completed work where possible |
| Installed | Chat or supported modality action | Delete | No transfer controls; resolve installed path without side effects |

Implementation requirements:

1. **Persistent state:** store model/file identity, expected totals, completed files, queued work, pause reason, and resumable transfer metadata sufficient to reconcile after restart. Reuse ModelsRepo and current download plans where possible. Treat resume data as a best effort; if unusable, explicitly restart only the affected file.
2. **Pause correctness:** the current coordinator removes files from queued when starting them, then does not requeue the active file when paused. Fix that ownership transition. Mark the model paused in persistent state and prevent fillSlots from scheduling it.
3. **Aggregate bytes:** Core currently overwrites a model's bytesDone with whichever file last reported. Track per-file progress and sum completed plus active bytes without double counting on resume. Preserve checksum validation.
4. **Task lifecycle:** handle HTTP failures, URLSession completion errors, cancellation, disk/write failures, and verification errors. Release slots on every terminal path and fill them fairly across queued models. A cancelled callback cannot mark a transfer installed or resurrect it.
5. **One authority:** coordinator/Core own state; SwiftUI owns presentation. Remove view-specific persisted pause flags once the coordinator stores the reason. Keep all screens synchronized through a shared observation/reload mechanism; a single bounded active-transfer poll is acceptable initially.
6. **Offline enforcement:** guard download creation/resume and queue scheduling, pause active internet transfers, and keep user/offline pauses distinct from connectivity loss. Merely creating a session with Net's configuration does not apply Net's offline/egress checks. Register/wire the coordinator where Core expects it, and prove the callback path with a test.
7. **Relaunch recovery:** recreate the background session early, reconnect task IDs to durable file/model identity, recover verification plans, and handle background completion delivery. Do not wait for Models to be opened.
8. **Deletion/cancel safety:** coordinate with active tasks and verification before removing partial files. Delete only the selected model's paths. Do not report deletion success if filesystem removal failed; don't erase a working installation when a new transfer is cancelled.
9. **Observed transfer reporting:** record app-controlled transfer requests/bytes in the existing Network Proof path. Make the scope of this count honest; it is not a packet-level OS monitor.
10. **Responsiveness:** hashing, disk scans, network search, and heavy metadata work run outside the main actor. Return UI state promptly and surface actionable errors instead of try?.

Background expectation: ordinary suspension/system termination can be reconciled with a background URLSession. A user force-quit cancels background transfers and prevents automatic relaunch; recover when the user opens the app again. Do not promise uninterrupted downloading after force-quit. See [Apple background session behavior](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)) and [background download integration](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).

## 9. Chat, model, and persistence contracts

### 9.1 One meaning for each model selection

| Value | Meaning | Where it belongs |
|---|---|---|
| Default model | Initial choice for a newly created conversation | Existing app preference, migrated from selectedModelId if renamed |
| Conversation model | Explicit choice for the next turn in one conversation | Existing conversation.model_id |
| Active turn model/peer | Immutable route captured when a turn starts | Active request state |
| Assistant message model | Model that actually produced that reply | Existing message.model_id, with readable location/provenance |
| Loaded model | A model actually resident in an engine | Engine/Core loaded state, never inferred from selection |

Resolve a conversation by ID using ConversationsRepo.get, not by searching the first page of conversations. Expose a small read API or extend the existing summary contract as needed. Resolve a default only when creating/binding an unbound chat, then persist the resulting choice.

Remove ChatView.send's global-model overwrite. Validate setConversationModel at the shared boundary: conversation exists, chosen route exists, capability is appropriate, and switching does not race an active turn. Apply successful changes atomically; a failed switch leaves the prior choice.

For remote IDs, resolve the peer encoded in mac:<peer-id>/<model-id>, never peers.first. Use that same peer for display, credentials, capability metadata, reconnect, and request routing. Retain pin verification and existing entitlement behavior. A stale or unavailable remote catalog is not evidence that every Mac model supports vision.

Apple's sentinel needs a resolvable model descriptor and routing that cannot be intercepted by generic MLX support. It is system-managed, not a zero-byte downloaded Hugging Face repository. Respect available context limits, preserve conversation roles in its prompt/session, and propagate real cancellation and availability errors.

### 9.2 Turn lifecycle, cancellation, and retry

- Keep active turn ownership outside a disposable ChatView state so navigation cannot lose the request identity. One active foreground chat generation is sufficient for this release; another chat offers Return to active chat or Stop and start.
- Carry a request ID through CoreClient, LiveCore, Rust send, and Engine.cancel. Cancelling an AsyncThrowingStream consumer alone does not cancel a synchronous engine call running on another task.
- Stop waits for the targeted request to terminate, persists its partial reply as Cancelled, and prevents late callbacks from overwriting a new turn. Do not cancel unrelated downloads or another conversation.
- Persist a streaming assistant record, update partial content at a bounded cadence, and record Done/Error/Cancelled. Reconcile leftover streaming records as Interrupted after a cold start; reuse the existing status representation with a displayed interruption reason if sufficient.
- A generation can continue while navigating within the foreground app. Backgrounding has a bounded cleanup/grace policy; save partial state and explain interruption when iOS cannot continue. Do not promise indefinite background MLX inference.
- Retry failed/stopped latest turns by existing user-message identity and full ContentParts. Exclude the failed attempt from the inference history. Keep the previous partial visible or replace it only with explicit retry semantics; never duplicate the user input.
- Keep oversized-message and smaller-context switches understandable. Preserve the stored transcript, retain the latest user prompt, truncate older context in complete turns, and show a clear error if the remaining required input still cannot fit.

### 9.3 Message parts, projects, and statistics

- Core's current send/messages reconstruction flattens input to text. Persist and restore the full supported parts representation, backward-compatible with old text-only JSON, then pass it through to the selected engine.
- For remote images, use the peer's supported content-parts transport with bounded, validated image data. A local filesystem path is not a usable image on another device. If the remote route lacks image support, disable it with a reason.
- For File/Project doc, reuse DocumentTextExtractor and project services. Keep original filename and useful import state, enforce supported type/size limits, and attach bounded extracted context rather than silently ignoring the action.
- Project chat currently has a project ID and a Sources UI but send does not inject retrieved project context. Connect existing retrieval/instructions to inference; store the exact source set used for that reply. Sources must show passages used in that answer, not a fresh unrelated search. Do not add a second retrieval engine.
- ImageGenerationSheet currently calls planDownload merely to get an installed directory; that changes the model's install state. Add/reuse a read-only installed-path accessor and remove that side effect.
- Persist complete available GenerateStats and decode them when loading history. Unknown values are absent/unavailable, not measured zero. Label character-derived live rates as estimates, or omit them.
- Pulse memory must distinguish app memory from model resident memory. Thermal state must come from the device, not a fixed Nominal string. Only show an unload action for a genuinely loaded model.
- Export readable model/location provenance and attachment descriptors. Never leak internal absolute paths or device credentials into exported Markdown.

### 9.4 Local summaries, recovery, and refresh

- Implement local summary/aggregate queries sufficient for Home and history: next-turn model, last reply model, latest preview, updated time, counts. Avoid one transcript read per row.
- Apply archive/search filters before pagination; load additional history pages. Do not interpret limit: 0 as “everything” where Core defaults to 50. Update conversation activity when a user/assistant message changes, not just when its title/model changes.
- Keep Archived accessible and allow Restore. Search with no matches keeps the search field and Clear search action available.
- Make onboarding's selected model become the real default. “Try Apple while downloading” must actually select Apple's route. Reuse the same model choice rules for Projects and App Intents.
- StartNewChatIntent must open the created conversation through the small navigation state used by Home. Intent copy must reflect whether the user-selected route can run on a Mac.
- If the real store fails to open, show a recoverable, clearly unavailable state with safe diagnostics. Do not silently expose PreviewCore sample chats/downloads as the user's real data, and do not recommend reinstalling as the default recovery.
- Network Proof needs an explicitly defined time window and result limit, including the current local day. The current limit: 0 path returns zero entries; fix the caller/API semantics together. If logs do not survive launch, label “this session” until durable today data is implemented; a Today label requires that persistence.

## 10. Additional findings from the source review

**P0** = incorrect execution, broken primary behavior, misleading trust claims, or data loss risk; fix before calling the redesign functional. **P1** = required usability/consistency work for this release. **V** = device/runtime verification needed; source suggests a cause but does not prove the observed symptom.

Path shorthand: I = PocketAI.Iphone; C = PocketAI.Core. Source locations are audit anchors, not claims of executed reproduction.

| ID | Priority | Evidence in the reviewed tree | Consequence / required fix |
|---|---|---|---|
| F01 | P1 | I/Sources/Models/ModelsView.swift:176; I/Sources/Settings/SettingsView.swift:155 | Fixed 110/80-point bottom padding reserves space; use safe areas (§3). |
| F02 | V/P1 | I/Sources/RootTabView.swift:149, TabBarMinimizeModifier | Global onScrollDown minimization is a candidate for the appearing Settings gear; capture and test stable tabs (§3). |
| F03 | P1 | I/Sources/Chats/ChatView.swift:68, 113, 238, 264 | Model inferred from last message; local subtitle absent; Ready sits below transcript. Use selected/active route header (§5). |
| F04 | P0 | I/Sources/Chats/ChatView.swift:789; Settings/SettingsDestinations.swift:29 | Each Send overwrites the conversation with the global local model; remote choices behave differently. Separate default and per-chat selection (§9.1). |
| F05 | P1 | C/crates/pocket-ffi/src/core.rs:636, 1556 | Title generator exists but uses only answer text, runs before final saved-message delivery, and can replace manual titles. Correct scheduling and atomic update (§5.2). |
| F06 | P0 | C/swift/Sources/PocketKit/Downloads/ModelDownloadCoordinator.swift:42–101; C/swift/Sources/PocketKit/Core/LiveCore.swift:44 | Pause/resume/cancel lack persistent model-state transitions; paused active files are removed without requeue. Repair the coordinator (§8). |
| F07 | P0 | Same coordinator:107–145; C/crates/pocket-ffi/src/core.rs:330 | No didCompleteWithError handling; slot/error handling gaps; per-file progress overwrites model total. Aggregate and reconcile correctly (§8). |
| F08 | P0 | Coordinator in-memory queued/active/resumeData; I/Sources/PocketAIApp.swift; Core/LiveCore.swift:init | No app background-event integration found; maps/plans are not reconstructed on launch. Prove suspension and restart recovery (§8). |
| F09 | P1 | I/Sources/Models/ModelsView.swift:202, 411, 441, 484 | Detail captures an entry snapshot; model rows lack rings; queued/verifying states omitted from installed-management filter; curated-only reloads hide some models. Use shared live identities (§6). |
| F10 | P0 | I/Sources/Models/ModelsView.swift:656; coordinator fillSlots; C/crates/pocket-ffi/src/core.rs:1343; LiveCore.init | Errors swallowed; network-online is confused with app Offline mode; coordinator creation is not registration/policy wiring. Enforce and test policy across every transfer (§8). |
| F11 | P0 | I/Sources/Chats/ChatView.swift:923; C/swift/Sources/PocketKit/Core/LiveCore.swift:93; AppleFoundationModelsEngine.swift:90 | UI Stop cancels the stream task, not necessarily engine work; Apple cancel is empty. Carry cancellation to request/engine (§9.2). |
| F12 | P0 | I/Sources/Chats/ChatView.swift:592, 930 | Assistant Retry copies assistant text into the composer and sends it as user input; reconnect can append another user turn. Retry by user-turn identity (§9.2). |
| F13 | P0 | C/crates/pocket-ffi/src/core.rs:474, 523, 565; I/Sources/Chats/ChatView.swift:1120; C/swift/Sources/PocketKit/Remote/RemoteEngine.swift:105 | Image parts are lost in persistence/reconstruction; images use temporary files; remote messages are flattened. Preserve parts and supported transport (§9.3). |
| F14 | P1 | I/Sources/Chats/ChatView.swift:285; C/crates/pocket-ffi/src/core.rs:515; I/Sources/Projects/SourceSheet.swift | File/Project doc are no-ops; project retrieval is not in normal send. Wire the offered functionality and grounded sources (§9.3). |
| F15 | P0 | C/swift/Sources/PocketKit/Remote/AppleFoundationModelsEngine.swift:15; C/crates/pocket-ffi/src/core.rs:1448; I/Sources/Onboarding/OnboardingFlow.swift:43 | Apple engine exists but its sentinel has no catalog/resolver entry; onboarding selection stays local to the flow. Make the advertised path usable (§7, §9.1). |
| F16 | P0 | I/Sources/AppModel.swift:54; I/Sources/Chats/ChatView.swift:120, 879; I/Sources/Models/ModelsView.swift:534 | Remote paths repeatedly use first peer despite IDs containing a peer identity. Resolve the chosen Mac for execution and labels (§9.1). |
| F17 | P0 | C/crates/pocket-store/src/services/chat.rs:list_conversations; C/crates/pocket-ffi/src/core.rs:540; I/Sources/Chats/ChatView.swift:748 | Default list limit is 50; send/header use that page to locate a conversation. Older chats can lose selected model/system prompt/title lookup. Fetch by ID (§9.1). |
| F18 | P1 | I/Sources/Chats/ChatsListView.swift:420; C/crates/pocket-ffi/src/core.rs:426; C/crates/pocket-store/src/services/chat.rs:create_message | History loads full transcripts per row; archive filtering follows pagination; message creation does not touch conversation activity. Correct summaries/pagination/activity (§9.4). |
| F19 | P0 | I/Sources/Settings/SettingsView.swift:160, 241; C/crates/pocket-ffi/src/core.rs:1355 | “Today” uses egressLog(limit: 0), but Core takes zero results and does not apply a day filter. Replace false-zero reporting with real scoped data (§9.4). |
| F20 | P1 | I/Sources/Models/ModelsView.swift:632, 732; I/Sources/Settings/SettingsDestinations.swift:93; I/Sources/Chats/ChatView.swift:93, 465, 822; C/crates/pocket-ffi/src/core.rs:491 | Runtime RAM shown as storage/download size; estimated speed can be marked measured; selected model shown as loaded; thermal fixed; saved stats omitted. Use correct data/unknown states (§9.3). |
| F21 | P1 | I/Sources/Chats/ChatView.swift:343; I/Sources/Chats/ChatsListView.swift:215, 485 | Destructive delete lacks confirmation/undo and open-chat dismissal; archive has no visible restore route. Complete safe lifecycle UI (§5.4). |
| F22 | P0 | I/Sources/AppModel.swift:76 | Real Core failure substitutes PreviewCore and suggests reinstalling. Protect real data and show an unavailable/recovery state (§9.4). |
| F23 | P1 | I/Sources/Settings/SettingsView.swift:149; I/project.yml | Version hardcoded to 0.2.0; reviewed project config defines application but no test targets despite UITests files. Use bundle version and restore actual test wiring (§12). |
| F24 | P0 | I/Sources/Chats/ImageGenerationSheet.swift:173; C/crates/pocket-ffi/src/core.rs:274 | Reading installed image-model path calls planDownload, resetting state to downloading. Add read-only lookup (§9.3). |
| F25 | P1 | C/crates/pocket-ffi/src/core.rs:171, 230, 1664; I/Sources/Models/ModelsView.swift:625, 645 | Catalog only iterates bundled entries; hub search returns unresolved manifests; unsupported models can still show Download; fallback may pick nonchat model. Merge persisted installs and enforce capabilities (§6, §9.1). |
| F26 | P1 | I/Sources/Chats/ChatView.swift:778, 490; I/Sources/Intents/StartNewChatIntent.swift | Draft clears early; leaving view removes pending image; shortcut creates chat but does not open it. Preserve drafts and open explicit destinations (§5.4, §9.4). |

Also check model deletion errors: core.rs:373 ignores remove_dir_all failure before deleting its database row. Surface that error and retain recoverable state. Check long prompts against truncate_to_fit, which can leave an oversized final prompt; reject or explain instead of producing a cryptic engine failure.

The listed findings cover the requested journeys and their shared data paths. They are not a security audit or proof that all other app features are defect-free.

## 11. Change map and implementation sequence

### 11.1 Reuse and likely touchpoints

| Area | Existing files/components to use | Contract/caller implications |
|---|---|---|
| App shell/Home | I/Sources/RootTabView.swift, AppModel.swift, PocketAIApp.swift; new I/Sources/Home/HomeView.swift | Home navigation, onboarding, App Intents, active chat identity, scene lifecycle |
| Chat UI/history | I/Sources/Chats/ChatView.swift, ChatsListView.swift, CameraCaptureView.swift, ImageGenerationSheet.swift | Drafts, source sheets, model picker, speech, exports, deletion |
| Shared presentation | C/swift/Sources/PocketUI/Components/Composer.swift, ModelRow.swift, DownloadProgress.swift, PulseStrip.swift, StatTile.swift; Mark/PocketMarkView.swift | Update Mac callers, component gallery, previews and snapshots when signatures change; keep Mac layout intact |
| Shared picker | Existing I/Sources/Settings/SettingsDestinations.swift DefaultModelPickerView; extract only the genuinely shared picker into a suitable iPhone Models file | Explicit scope for default vs current chat; shared capability/availability resolution |
| Models/downloads | I/Sources/Models/ModelsView.swift, I/Sources/Onboarding/OnboardingFlow.swift; C/swift/Sources/PocketKit/Downloads/ModelDownloadCoordinator.swift | Home/Storage/details/onboarding all consume the same state and actions |
| Settings/privacy | I/Sources/Settings/SettingsView.swift, SettingsDestinations.swift; C/swift/Sources/PocketKit/Net/Net.swift | Accurate values; offline/download coupling; bounded query scope |
| Swift API | C/swift/Sources/PocketKit/Core/CoreClient.swift, LiveCore.swift, Preview/PreviewCore.swift | Keep protocol, production implementation, fixtures and all callers in sync |
| Rust API/store | C/crates/pocket-ffi/src/core.rs, types.rs, traits.rs, core_tests.rs; pocket-store/src/repos and services/chat.rs | Add minimal APIs/fields for direct reads, cancellation, metadata, aggregate stats and transfer state; backward-compatible storage |
| Engines/remote | C/swift/Sources/PocketKit/Remote/AppleFoundationModelsEngine.swift, LazyRemoteEngine.swift, RemoteEngine.swift; C/swift/Sources/PocketMLX/RoutingEngine.swift, PocketMLXEngine.swift | Apple availability/cancellation, explicit peer identity, content parts, load/unload behavior |
| Projects/files | I/Sources/Projects/ProjectDetailView.swift, SourceSheet.swift; C/swift/Sources/PocketKit/Documents/DocumentTextExtractor.swift and existing Rust retrieval | Reuse extraction/retrieval; preserve exact citations and imported content |
| Tests/config | I/project.yml, UITests/*; C/swift/Tests/*; C/crates/pocket-ffi/src/core_tests.rs and pocket-store tests | Real test targets/schemes, fixtures, package and shared Mac compilation |

I and C refer to the repository roots defined in §10. Within a cell, unprefixed filenames share the preceding directory unless stated otherwise. Prefer finding symbols with rg over relying on line numbers.

Generated Swift FFI bindings and the XCFramework must be regenerated with the existing build script whenever the Rust API changes. Do not hand-edit generated bindings or PocketAI.xcodeproj. Update project.yml for targets/resources/schemes. Keep dependencies unchanged unless an existing capability genuinely cannot satisfy a requirement.

### 11.2 Ordered work packages

Implement small, reviewable stages. Record findings and tests after each stage in an implementation checklist. Do not mark a stage done merely because its UI compiles.

| Stage | Work | Dependencies | Exit evidence |
|---|---|---|---|
| T0 — Baseline | Inspect current diffs; capture reported glitches; establish runnable app/test targets; seed realistic fixtures | None | Baseline build result, device/simulator/OS recorded, current screenshots and failing-path notes |
| T1 — Identity and read model | Separate default/conversation/active model; direct conversation lookup; peer-specific routing; Apple descriptor/availability; summary reads and noncurated installed visibility | T0 | Local→local, local→Mac, Mac→local, and Apple selection tests; older-chat lookup and metric tests |
| T2 — Transfers and privacy | Repair pause/resume/cancel, aggregate progress, queue/error lifecycle, persistence/recovery, offline enforcement, egress reporting | T0 | Real small-file transfer tests plus device background/relaunch evidence; no false completed states |
| T3 — Chat behavior | Request cancellation, safe retry, parts/drafts/partial persistence, title policy, stats, project/attachment behavior, read-only image-model lookup | T1 | Regression tests for retry, Stop, manual title race, attachments and interruption; existing text history opens |
| T4 — Shell and Home | Five stable tabs, safe areas, Home aggregates/models/downloads/recent chats, exact navigation and shortcut integration | T1, T2 | Home counts match data; recent-chat/deep-link routes pass; no gear collapse or fixed bottom void |
| T5 — Chat and history UI | New status/title/model header, picker, highlighted composer, archive/recovery/search states, message provenance | T3, T4 | Light/dark/AX snapshots; keyboard, scroll, draft, model-switch and delete flows pass |
| T6 — Models and Settings UI | Filters/sort/compact rows, main-list rings, live detail, default/Apple picker, storage, real version/engine availability | T1, T2, T4 | All U4–U7 flows pass from UI against production services and fixtures where appropriate |
| T7 — Release verification | Cross-screen states, accessibility, persistence/migration, real hardware and shared Mac regression | T5, T6 | Acceptance matrix below has evidence or explicit blocked checks; remaining blockers reported honestly |

T2 and T1 are largely independent, but shared API edits must stay coherent. This ordering is not a requirement to spawn multiple agents.

### 11.3 Storage and compatibility rules

- Reuse existing conversation.model_id, message.model_id, content_json, stats_json, and status. Add fields only when the requirement cannot be represented safely with what exists.
- Old text-only messages must decode without migration loss. Any schema change has an additive/versioned migration and a test opening a pre-change database fixture.
- Preserve manual titles; backfill unknown title ownership conservatively. Do not rewrite every old title automatically.
- Retain historical model identity even when weights are deleted or a peer is unpaired. Fall back to a readable saved/raw name instead of relabeling the reply as current-model output.
- Reconcile old app preference and paused-download flags once. Do not maintain competing “selected model” stores after migration.
- Carry changed contracts through PreviewCore, CoreClient, generated FFI, fixtures, Mac callers, Projects, and App Intents. Current pending work already adds setConversationModel; use and validate it rather than creating a parallel setter.

## 12. Acceptance and verification

### 12.1 Required functional scenarios

| Test | Scenario and expected result | Coverage |
|---|---|---|
| A01 | First launch with no downloaded model: useful Home/onboarding state; Apple works if eligible; otherwise Browse/Pair action; no fabricated Ready | U3, U7, F15, F22 |
| A02 | First completed exchange gets a meaningful title; failed title uses fallback; concurrent manual rename survives; reopening preserves it | U1, F05 |
| A03 | Header always names selected/active model and location; state mark animates during real work and stops; composer focus is visible | U1, U2, F03 |
| A04 | Change default in Settings while an existing chat uses another model; only new conversations inherit the new default | U7, U8, F04 |
| A05 | Switch model inside a chat through local/Mac/Apple choices; history and draft survive; stop before switching a running turn; unavailable route is explained | U2, U8, F11, F15 |
| A06 | Two paired-peer fixtures: selecting the second peer uses its credentials/endpoint/name, including reconnect; unpairing leaves history readable | F16 |
| A07 | Real two-file transfer: list/detail/Home agree; Pause freezes scheduling/progress after callback settlement; Resume completes with correct summed bytes and hashes | U6, F06, F07, F09 |
| A08 | Queue more than three files across models; errors/cancelled tasks release capacity; another model is not starved; repeated taps create no duplicate tasks | U6, F07 |
| A09 | Cancel active/queued/paused download; files and state reconcile; late callbacks do not resurrect it; unrelated installed model and files remain | U6 |
| A10 | Network loss/reconnect versus explicit Pause versus Offline mode: only connectivity-interrupted work auto-recovers; user/offline pauses remain paused | U6, F10 |
| A11 | Background, lock/unlock, system interruption and manual relaunch: known transfer state restored; force-quit has truthful recovery wording | U6, F08 |
| A12 | Bad checksum, HTTP failure, disk full, malformed URL, file move failure, unusable resume data: clear error/retry state; never falsely Installed | U6, F07 |
| A13 | All/Text/Vision/Voice/Images plus Fits/search/sort produce correct results; installed/active items remain manageable; no-results state clears correctly | U4, U5, F25 |
| A14 | Installed models from outside curated entries appear consistently; unknown/unsupported hub models cannot pretend to be usable downloads | U3, U5, F09, F25 |
| A15 | Home counts/most-used model match deterministic fixtures including archived chats, remote replies, failed/stopped turns, and title requests | U3 |
| A16 | Seed at least 120 chats with archived entries; browse/search/paginate; open the oldest chat; correct title/model/system prompt and recent ordering | F17, F18 |
| A17 | Retry assistant reply regenerates the corresponding user turn, preserving image/file context; reconnect does not duplicate input; earlier retry preserves later history | F12, F13 |
| A18 | Stop produces a saved partial/cancelled answer and no late overwrite; a new turn can start after engine termination; interruption never leaves an endless spinner | F11 |
| A19 | Attach image, send, relaunch: thumbnail/content remains; selected VLM actually receives image; incompatible model switch explains mismatch | F13 |
| A20 | File/Project doc import shows extraction/errors; project answer receives retrieved context; Sources match that answer; image generation does not change installation state | F14, F24 |
| A21 | Navigate away/back with unsent draft and attachment; both survive; failed send recovers them; successful deletion cleans only owned files | F21, F26 |
| A22 | Archive/Restore, Rename, Delete confirmation/cancel, delete open chat, Export, search no matches, Home recent-chat navigation all work | F21, F26 |
| A23 | Apple unavailable/not-enabled/not-ready fixtures show useful reasons; real eligible iPhone answers and cancels; no Pro or Hugging Face error for Apple | U7, F15 |
| A24 | Network Proof reports actual scoped recorded requests; local-day boundary and relaunch tested; offline blocks app internet while allowing permitted paired LAN usage | F10, F19 |
| A25 | Storage uses disk bytes; optional speed/RAM/thermal stats have correct units/provenance; history reload preserves real available stats; About matches bundle | F20, F23 |
| A26 | Core open failure never masquerades as real sample data; pre-change data fixture opens after migration with history/models intact | F22 |
| A27 | Settings and Models scroll without artificial bottom gaps or collapsing gear; keyboard appearance/dismissal and long composer do not obscure final message | U4, U7, F01, F02 |
| A28 | App Intent starts the exact new chat; onboarding default survives; new project chat follows default rules; shared Mac consumers build and smoke-test | F26, shared contracts |

### 12.2 Visual, accessibility, and performance checks

- Capture Home, chat empty/streaming/error, model picker, Models installed/browse/downloading, model detail, and Settings in light and dark mode.
- Cover the smallest supported iPhone width and a large iPhone, plus normal and accessibility text sizes. Required previews: light, dark, AX3; also manually verify reflow at AX5.
- VoiceOver: model and route are announced, download percent and actions make sense, controls have 44-point hit areas, and streaming announces completion rather than every token.
- Reduce Motion, Reduce Transparency, Increase Contrast, keyboard/Dictation, long titles/model names, RTL/pseudolocalized strings, and multiline/code replies.
- No permanent animation while idle, no forced autoscroll when reading history, no blank footer created by a magic number.
- Use existing performance tooling to check scrolling a large seeded history and streaming a long response. Record the device and observations; avoid invented speed claims or arbitrary performance numbers.
- Hashing/download restoration/search/summary scans must not visibly block interaction. Reuse existing main-thread diagnostics where available.

### 12.3 Test layers and commands

At review time the iPhone project.yml only declares the application target. Existing UITests source files alone do not prove tests are in a generated testable scheme. T0 must wire test targets/schemes through XcodeGen and confirm discovery before claiming a green test run.

Use existing tests:

- I/UITests/ChatFlowUITests.swift, DownloadStateUITests.swift, SettingsFlowUITests.swift, AccessibilityAuditTests.swift, PerfTests.swift.
- C/swift/Tests/PocketKitTests, PocketMLXTests, PocketUITests (including snapshots and contrast tests).
- C/crates/pocket-ffi/src/core_tests.rs and pocket-store unit tests.

Add focused regression tests for the defects above. In particular, PreviewCore's simulated download test cannot validate ModelDownloadCoordinator. Use deterministic small files from a controlled local HTTP fixture server for real transport tests; test genuine background session behavior on device separately. Use cached/installed models for real inference checks where available.

Suggested workflow, from each indicated repository:

~~~sh
# PocketAI.Core: run targeted tests while developing, then required workspace checks
cargo test -p pocket-store -p pocket-ffi
cargo build --workspace
cargo test --workspace
scripts/build-xcframework.sh
swift test

# PocketAI.Iphone: after declaring appropriate test targets/schemes in project.yml
xcodegen generate
xcodebuild -list
xcodebuild -scheme PocketAI -showdestinations
xcodebuild -scheme PocketAI -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -scheme PocketAI -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
~~~

Use an installed simulator name if different; record the actual destination. MLX inference is not supported by the repository's simulator workflow: simulator/PreviewCore checks validate UI, not hardware inference. Run local text/vision and Apple checks on an eligible physical iPhone, and remote routing with a paired Mac. Build the Mac app after shared API/component changes and smoke-test its affected routes.

Do not keep repeating already-green full suites without a new change or concern. Record which tests ran, failed, were skipped, or require hardware; distinguish them from planned checks.

## 13. Definition of done and handoff back to the owner

- [ ] U1–U8 implemented with their acceptance scenarios.
- [ ] All P0 findings resolved with targeted regression evidence.
- [ ] Required P1 findings resolved; no inert enabled control in the changed journeys.
- [ ] Source-only hypotheses, especially the scrolling gear, reproduced or clearly explained with device evidence.
- [ ] Production downloads, Stop/retry, persistence, Apple, and selected-Mac routing tested beyond PreviewCore.
- [ ] All affected protocols/callers/generated bindings/fixtures updated; shared Mac consumers remain functional.
- [ ] Previous user data opens without reset and installed models remain valid.
- [ ] Required builds/tests and accessibility checks run; hardware/environment blockers named explicitly.
- [ ] Before/after screenshots and a short evidence checklist saved under iPhone docs.
- [ ] Final implementation report lists completed work, checks run, remaining issues, and any data/compatibility risks.

Do not mark the whole goal complete while a required real-device behavior is unverified. Finish all feasible implementation and tests, then report the exact remaining validation requirement rather than replacing it with a simulated pass.

## 14. Deliberately deferred

No new cloud providers, accounts, analytics uploads, conversation synchronization, model fine-tuning, general agent tools, theme system, gamification, live widgets, image editor, or new speech/image inference backend. No broad Mac redesign. Conversation branching as a product feature, custom prompt/parameter editors, and per-modality default settings beyond the existing supported workflows can follow this release.

These deferrals do not permit dropping any U1–U8 requirement or disguising an existing broken primary action. For a modality whose engine is not shipped, show an honest unavailable state rather than building a new backend as part of UI polish.
