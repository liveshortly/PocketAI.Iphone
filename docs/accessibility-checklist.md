# PocketAI Accessibility Manual Verification Checklist (QA-10)

> **Context**: Automated accessibility audits (`XCUIApplication.performAccessibilityAudit()`) run via `UITests/AccessibilityAuditTests.swift` to catch structural issues (missing labels, broken traits, invalid hierarchies). This document defines the **manual QA verification pass** covering auditory, visual, motor, and cognitive user experiences on physical hardware.
>
> *Note*: Per-component accessibility labels, hints, traits, and values are already present throughout `PocketUI` and the application views (`Composer`, `SettingsView`, `ChatsListView`, `OnboardingFlow`, etc.).

---

## 1. VoiceOver Full Navigation Pass (iOS & macOS)

Perform complete end-to-end task flows using only VoiceOver screen reader gestures / keyboard shortcuts.

### iOS (iPhone)
- [ ] **Onboarding & Permissions**:
  - VoiceOver speaks screen headings and step transitions ("Step 1 of 5: Welcome to PocketAI").
  - Model recommendation explanation is read in logical flow before action buttons.
  - Camera & microphone permission prompts clearly explain the purpose and consequences of access.
- [ ] **Chats List & Navigation**:
  - "New chat" button announced with proper button trait and accessibility label.
  - Segmented control ("Chats" vs "Projects") announces selected tab and position.
  - Chat list rows read title, timestamp, and preview text without clipping.
  - Swipe actions (Delete, Archive) accessible via VoiceOver Actions rotor.
- [ ] **Chat & Composer**:
  - Assistant message streaming: does not spam VoiceOver live regions continuously; announces completion with token count and decode speed.
  - Reasoning disclosure ("Thought process") can be expanded and collapsed with VoiceOver activation.
  - Composer input field announces "Message, text field, multi-line".
  - Trailing button states announced accurately:
    - Empty: "Voice input, double-tap to dictate, double-tap and hold for hands-free send"
    - Text entered: "Send, button"
    - In-flight generation: "Stop generating, button"
  - Copy, retry, and speak aloud actions accessible via context menus or direct action buttons.
- [ ] **Models Catalog**:
  - Each model card announces model name, parameter size, quantization format (e.g. 4-bit), and memory requirements.
  - Download buttons announce progress updates at 10% increments rather than every byte.
- [ ] **Settings & Network Proof**:
  - Toggles announce current state ("Share diagnostic reports, On/Off, Double-tap to toggle").
  - Network Proof counter announces total requests made and explains offline policy.
- [ ] **Paywall & Activation**:
  - Lifetime license features read in order with checkmark indicators.
  - Price buttons clearly announce billing amount and restore purchases link.

### macOS (Mac Companion)
- [ ] **VoiceOver Cursor**: VO navigation (`Control-Option-Arrow`) logically traverses sidebar, conversation history, and composer.
- [ ] **Quick Nav**: Arrow keys navigate through list items and buttons seamlessly.

---

## 2. Dynamic Type at Maximum Size (AX5)

Enable **Settings > Accessibility > Display & Text Size > Larger Text** and drag slider to the maximum Accessibility size (**AX5**).

- [ ] **Text Wrapping & Truncation**:
  - No text is truncated with ellipses (`...`) where full content is critical (disclaimers, model names, instructions).
  - Headings and body copy expand vertically without clipping.
- [ ] **Touch Target Integrity**:
  - All interactive buttons, chips, and list cells maintain minimum 44×44 pt touch targets.
  - Trailing composer buttons remain tappable and do not collide with multi-line text.
- [ ] **Tab Bar & Navigation Bars**:
  - Tab bar items scale or switch to Large Content Viewer on long press.
  - Navigation titles wrap or truncate cleanly without pushing action buttons off-screen.
- [ ] **Message Bubbles**:
  - User and assistant speech bubbles expand horizontally to screen margins and wrap cleanly.
  - Citations and thumbnail attachments scale proportionally without horizontal overflow.

---

## 3. Display & Motion Accommodations

### Reduce Motion
Enable **Settings > Accessibility > Motion > Reduce Motion**.
- [ ] Screen transitions between onboarding steps use gentle cross-fades rather than lateral slides.
- [ ] Streaming pulse strip animation disables pulsing pulse waves and displays static generating indicator.
- [ ] Sheets and modals present without bouncy spring dynamics.

### Reduce Transparency
Enable **Settings > Accessibility > Display & Text Size > Reduce Transparency**.
- [ ] Blurred materials (`.ultraThinMaterial`, `.regularMaterial`) fall back to high-opacity sunken canvas backgrounds.
- [ ] Text overlaid on materials remains sharp and legible with high contrast against solid fills.

### Increase Contrast
Enable **Settings > Accessibility > Display & Text Size > Increase Contrast**.
- [ ] Card borders and list separators become distinctly visible against canvas backgrounds.
- [ ] Primary accent colors (`PocketColor.accent`) and status badges (`PocketColor.statusWarn`, `PocketColor.statusBad`) achieve ≥ 7:1 contrast ratio against light and dark backgrounds.
- [ ] Disabled elements maintain distinguishable luminance separation from background.

### Differentiate Without Color
Enable **Settings > Accessibility > Display & Text Size > Differentiate Without Color**.
- [ ] Error notices, offline mode warnings, and battery alerts include distinct icons and labels in addition to color.

---

## 4. Full Keyboard Access (FKA) & Mac Keyboard-Only Navigation

Enable **Settings > Accessibility > Keyboards > Full Keyboard Access** on iOS, and test standard keyboard input on macOS.

- [ ] **Tab Navigation Order**:
  - `Tab` and `Shift-Tab` move focus logically from top to bottom, left to right.
  - Focus moves into sheets and modals when opened and returns to trigger element when dismissed.
- [ ] **Focus Rings**:
  - High-visibility focus ring surrounds the active interactive element on both light and dark themes.
- [ ] **Keyboard Shortcuts**:
  - `Return` or `Command-Return`: Sends composer message.
  - `Escape`: Dismisses sheets, popovers, and alerts.
  - `Command-N`: Creates a new chat.
  - `Command-Comma`: Opens Settings.
  - `Space` / `Return`: Triggers focused button or activates toggle.
  - `Arrow Keys`: Moves between segmented control options ("Chats" / "Projects").

---

## 5. Screen-by-Screen Sign-Off Matrix

| Screen Surface | VoiceOver | Dynamic Type AX5 | Reduce Motion | Increase Contrast | Keyboard Only | Tester Sign-Off |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **Onboarding** (`OnboardingFlow`) | [ ] | [ ] | [ ] | [ ] | [ ] | |
| **Chats List** (`ChatsListView`) | [ ] | [ ] | [ ] | [ ] | [ ] | |
| **Chat & Pulse** (`ChatView`) | [ ] | [ ] | [ ] | [ ] | [ ] | |
| **Models Catalog** (`ModelsView`) | [ ] | [ ] | [ ] | [ ] | [ ] | |
| **Settings & Privacy** (`SettingsView`) | [ ] | [ ] | [ ] | [ ] | [ ] | |
| **Pro Paywall** (`PaywallView`) | [ ] | [ ] | [ ] | [ ] | [ ] | |
| **Network Proof** (`NetworkProofView`) | [ ] | [ ] | [ ] | [ ] | [ ] | |
| **Shared Inbox Ingest** (`SharedInboxIngestSheet`) | [ ] | [ ] | [ ] | [ ] | [ ] | |

---

## 6. Physical Hardware QA Gate (Per `strategy/DEVICES.md`)

- [ ] Tested on **iPhone 17 Pro** (Owner hardware, iOS 26 / newest OS ceiling).
- [ ] Tested on **iPhone 13** (Floor hardware, 6 GB RAM, iOS 18 minimum deployment target).
- [ ] Tested on **Apple Silicon Mac** (macOS companion keyboard & VoiceOver navigation).
