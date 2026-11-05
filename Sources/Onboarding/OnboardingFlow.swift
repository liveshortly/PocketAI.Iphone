import SwiftUI
import PocketKit
import PocketUI

/// UI-07: Redesigned iPhone onboarding flow (`02-design-system.md` §7.1).
/// Features a centered glowing PocketMark, large rounded display typography,
/// premium benefit cards, paced hardware checklist animation, curated first
/// model selection with FitBadges, and a ready state.
public struct OnboardingFlow: View {
    public enum Step: Int { case welcome, deviceCheck, pickModel, downloading, ready }

    private let core: CoreClient
    private let deviceProfile: DeviceProfile
    private let onFinished: () -> Void

    @State private var step: Step = .welcome
    @State private var selectedModelId: String?
    @State private var catalog: [CatalogEntry] = []
    @State private var downloadStartError: String?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    public init(core: CoreClient, deviceProfile: DeviceProfile, onFinished: @escaping () -> Void) {
        self.core = core
        self.deviceProfile = deviceProfile
        self.onFinished = onFinished
    }

    /// The step Back returns to, nil where there is no Back. The device check
    /// advances by itself (unless VoiceOver is on), so Back from Pick skips
    /// it instead of bouncing the user straight forward again.
    private var backStep: Step? {
        switch step {
        case .deviceCheck: .welcome
        case .pickModel: voiceOver ? .deviceCheck : .welcome
        default: nil
        }
    }

    public var body: some View {
        Group {
            switch step {
            case .welcome:
                OnboardingWelcomeView {
                    withAnimation(PocketMotion.standard) {
                        step = .deviceCheck
                    }
                }
            case .deviceCheck:
                OnboardingDeviceCheckView(profile: deviceProfile) {
                    catalog = core.catalog(filter: CatalogFilter(modality: .text, curatedOnly: true, installedOnly: false))
                    withAnimation(PocketMotion.standard) {
                        step = .pickModel
                    }
                }
            case .pickModel:
                OnboardingPickModelView(catalog: catalog) { modelId in
                    selectedModelId = modelId
                    // F15/§9.4: the picked model becomes the real default, so new
                    // chats start on it after onboarding — not a flow-local value.
                    if let modelId { AppModel.shared.selectedModelId = modelId }
                    if let modelId, modelId != AppleFoundationModelsEngine.modelId {
                        do {
                            try core.startDownload(modelId: modelId)
                            withAnimation(PocketMotion.standard) {
                                step = .downloading
                            }
                        } catch {
                            // Stay on the picker and say why (disk/offline) —
                            // never a silent dead end.
                            downloadStartError = error.localizedDescription
                        }
                    } else if modelId == nil {
                        // UI-54: nothing fits / skipped. "You're ready" would be
                        // untrue; Home's Model card says "No model yet — Get one".
                        onFinished()
                    } else {
                        withAnimation(PocketMotion.standard) {
                            step = .ready
                        }
                    }
                }
            case .downloading:
                OnboardingDownloadingView(
                    core: core,
                    modelId: selectedModelId ?? "",
                    onSkipToApple: AppleFoundationModelsEngine.isAvailable ? {
                        // "Try Apple while downloading" actually selects Apple's
                        // route as the default (F15), keeping the download going.
                        AppModel.shared.selectedModelId = AppleFoundationModelsEngine.modelId
                        withAnimation(PocketMotion.standard) {
                            step = .ready
                        }
                    } : nil,
                    onBack: {
                        // Cancel returns to the model picker — never a dead end.
                        withAnimation(PocketMotion.standard) {
                            step = .pickModel
                        }
                    },
                    onReady: {
                        withAnimation(PocketMotion.standard) {
                            step = .ready
                        }
                    }
                )
            case .ready:
                OnboardingReadyView(onStart: { suggestion in
                    if let suggestion {
                        AppModel.shared.nav.startNewChat(firstMessage: suggestion)
                    }
                    onFinished()
                })
            }
        }
        .animation(.default, value: step)
        .background(PocketColor.bgCanvas)
        // UI-58: Back between Welcome, Device check and Pick. Downloading
        // has its own Cancel; Ready is the end.
        .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            if let previous = backStep {
                Button {
                    withAnimation(PocketMotion.standard) { step = previous }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.pocket(.body))
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .tint(PocketColor.accent)
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .accessibilityIdentifier("onboarding_back")
            }
        }
        .alert("Couldn't start the download", isPresented: Binding(
            get: { downloadStartError != nil },
            set: { if !$0 { downloadStartError = nil } }
        )) {
            Button("OK", role: .cancel) { downloadStartError = nil }
        } message: {
            Text(downloadStartError ?? "")
        }
    }
}

// MARK: - Welcome View

private struct OnboardingWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: PocketSpacing.s24) {
                Spacer(minLength: PocketSpacing.s20)

                PocketMarkView(state: .idle, size: 96)
                    .padding(.bottom, PocketSpacing.s8)

                VStack(spacing: PocketSpacing.s8) {
                    Text("Private AI that lives on your devices.")
                        .font(.pocket(.display))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(PocketColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("No cloud. No account. Nothing leaves.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The hero was the only block without a gutter, so its display
                // type ran edge-to-edge on every device.
                .padding(.horizontal, PocketSpacing.gutterIphone)

                VStack(spacing: PocketSpacing.s12) {
                    benefitCard(
                        icon: "iphone.gen3",
                        title: "Runs on this iPhone, even offline",
                        subtitle: "Answers are made right here. No internet needed."
                    )
                    benefitCard(
                        icon: "lock.shield.fill",
                        title: "Nothing leaves without you seeing it",
                        subtitle: "Every connection is listed in Settings."
                    )
                    benefitCard(
                        icon: "laptopcomputer",
                        title: "Use your Mac's bigger models",
                        subtitle: "Pair once, then chat with your Mac's models from here."
                    )
                }
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.vertical, PocketSpacing.s8)

                Spacer(minLength: PocketSpacing.s20)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onContinue()
                } label: {
                    Text("Get started")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.accentOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PocketSpacing.s12)
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.bottom, PocketSpacing.s16)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func benefitCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            ZStack {
                RoundedRectangle(cornerRadius: PocketRadius.chip, style: .continuous)
                    .fill(PocketColor.accentSoft)
                    .frame(width: PocketSpacing.s40, height: PocketSpacing.s40)
                Image(systemName: icon)
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                Text(title)
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .padding(PocketSpacing.s12)
        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
        .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
    }
}

// MARK: - Device Check View

private struct OnboardingDeviceCheckView: View {
    let profile: DeviceProfile
    let onContinue: () -> Void

    @State private var revealedRows = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// UI-58: ~1.3 s is too fast to read under VoiceOver; wait for the user.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private var rows: [String] {
        var r = [
            String(localized: "\(profile.chip) · \(formatBytes(profile.totalRamBytes)) memory · up to \(formatBytes(profile.appMemoryLimitBytes)) for models"),
            String(localized: "\(formatBytes(profile.freeDiskBytes)) free storage"),
        ]
        if AppleFoundationModelsEngine.isAvailable {
            r.append("Apple Intelligence available")
        }
        return r
    }

    var body: some View {
        // Centred when it fits, scrollable when Dynamic Type makes it taller
        // than the screen — never clipped.
        ViewThatFits(in: .vertical) {
            checklist
            ScrollView { checklist }
        }
        .task {
            for _ in rows {
                try? await Task.sleep(nanoseconds: 280_000_000)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation { revealedRows += 1 }
            }
            guard !voiceOver else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            onContinue()
        }
    }

    private var checklist: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer(minLength: PocketSpacing.s24)

            ZStack {
                Circle()
                    .fill(PocketColor.accentSoft)
                    .frame(width: 72, height: 72)
                PocketMarkView(state: .loading, size: 40)
            }

            Text("Checking your device")
                .font(.pocket(.display))
                .foregroundStyle(PocketColor.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PocketSpacing.gutterIphone)

            VStack(spacing: PocketSpacing.s12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index < revealedRows {
                        HStack(spacing: PocketSpacing.s12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.pocket(.headline))
                                .foregroundStyle(PocketColor.statusOk)
                                .accessibilityHidden(true)
                            Text(row)
                                .font(.pocket(.body))
                                .foregroundStyle(PocketColor.textPrimary)
                            Spacer()
                        }
                        .padding(PocketSpacing.s12)
                        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
                        .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
                        // §3.4: Reduce Motion gets cross-fades only.
                        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)

            Spacer(minLength: PocketSpacing.s24)

            Text("We read this on your device. It is never sent anywhere.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.bottom, voiceOver ? 0 : PocketSpacing.s24)

            if voiceOver {
                Button(action: onContinue) {
                    Text("Continue")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.accentOnAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.bottom, PocketSpacing.s16)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

// MARK: - Pick Model View

private struct OnboardingPickModelView: View {
    let catalog: [CatalogEntry]
    let onPick: (String?) -> Void

    private var recommended: CatalogEntry? {
        catalog.first { $0.manifest.tags.contains("recommended") && $0.fit.verdict == .runsWell }
            ?? catalog.first { $0.fit.verdict == .runsWell }
    }

    /// §1.4 "fit before download": never offer a model that won't run here.
    private var alternates: [CatalogEntry] {
        catalog.filter {
            $0.manifest.id != recommended?.manifest.id
                && ($0.fit.verdict == .runsWell || $0.fit.verdict == .runsSlow)
        }.prefix(2).map { $0 }
    }

    /// Real download size, the same rule for every card.
    private func downloadSize(_ e: CatalogEntry) -> String {
        formatBytes(e.fit.diskBytes != 0 ? e.fit.diskBytes : e.manifest.estRuntimeBytes)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: PocketSpacing.s24) {
                VStack(spacing: PocketSpacing.s8) {
                    Text("Pick your first model")
                        .font(.pocket(.display))
                        .foregroundStyle(PocketColor.textPrimary)

                    Text("We checked which ones fit this iPhone.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, PocketSpacing.s16)

                if recommended == nil, alternates.isEmpty, !AppleFoundationModelsEngine.isAvailable {
                    // Never a dead end: an empty catalog (or nothing that fits)
                    // still lets the user in; Home then offers "Get one".
                    VStack(spacing: PocketSpacing.s12) {
                        Text("No model fits this iPhone right now. You can browse more in Models later.")
                            .font(.pocket(.callout))
                            .foregroundStyle(PocketColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Continue without a model") { onPick(nil) }
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.accent)
                            .frame(minHeight: 44)
                    }
                }

                if AppleFoundationModelsEngine.isAvailable {
                    OnboardingAppleCard { onPick(AppleFoundationModelsEngine.modelId) }
                }

                if let recommended {
                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        Text("Recommended for this iPhone")
                            .font(.pocket(.footnote))
                            .fontWeight(.semibold)
                            .foregroundStyle(PocketColor.accent)

                        ModelRow(
                            data: ModelRowData(
                                name: recommended.manifest.displayName,
                                familyParamsQuant: "\(recommended.manifest.family) · \(recommended.manifest.quant)",
                                fitKind: fitKind(recommended.fit.verdict),
                                fitReason: recommended.fit.reason,
                                sizeOnDisk: downloadSize(recommended),
                                speedText: recommended.fit.estTokensPerSec.map { "\(Int($0)) tok/s" },
                                speedIsMeasured: false,
                                licenseLabel: recommended.manifest.license.spdx
                            ),
                            primaryActionLabel: String(localized: "Download \(downloadSize(recommended))"),
                            onPrimaryAction: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onPick(recommended.manifest.id)
                            }
                        )
                        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
                        .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))

                        HStack(spacing: PocketSpacing.s4) {
                            Image(systemName: "wifi")
                                .accessibilityHidden(true)
                            Text("Wi-Fi recommended")
                        }
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                    }
                }

                if !alternates.isEmpty {
                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        Text("Other options")
                            .font(.pocket(.footnote))
                            .fontWeight(.semibold)
                            .foregroundStyle(PocketColor.textSecondary)

                        ForEach(alternates, id: \.manifest.id) { entry in
                            ModelRow(
                                data: ModelRowData(
                                    name: entry.manifest.displayName,
                                    familyParamsQuant: "\(entry.manifest.family) · \(entry.manifest.quant)",
                                    fitKind: fitKind(entry.fit.verdict),
                                    fitReason: entry.fit.reason,
                                    sizeOnDisk: downloadSize(entry),
                                    speedText: entry.fit.estTokensPerSec.map { "\(Int($0)) tok/s" },
                                    speedIsMeasured: false,
                                    licenseLabel: entry.manifest.license.spdx
                                ),
                                primaryActionLabel: "Choose",
                                onPrimaryAction: {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    onPick(entry.manifest.id)
                                }
                            )
                            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
                            .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
                        }
                    }
                }
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.bottom, PocketSpacing.s32)
        }
    }

    private func fitKind(_ verdict: FitVerdict) -> FitBadgeKind {
        switch verdict {
        case .runsWell: return .runsWell
        case .runsSlow: return .runsSlow
        case .willNotFit: return .willNotFit
        case .notSupported: return .notSupported
        }
    }
}

private struct OnboardingAppleCard: View {
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: PocketSpacing.s12) {
                ZStack {
                    RoundedRectangle(cornerRadius: PocketRadius.chip, style: .continuous)
                        .fill(PocketColor.bgSunken)
                        .frame(width: PocketSpacing.s40, height: PocketSpacing.s40)
                    Image(systemName: "apple.logo")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                    Text("Start instantly with Apple Intelligence")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text("No download. Built into this iPhone.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
            .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Downloading View

private struct OnboardingDownloadingView: View {
    let core: CoreClient
    let modelId: String
    let onSkipToApple: (() -> Void)?
    let onBack: () -> Void
    let onReady: () -> Void

    @State private var entry: CatalogEntry?
    /// A Retry that can't start (no disk, offline mode) has to say so — the
    /// state stays `.failed`, so the button otherwise looks dead.
    @State private var retryError: String?

    private var isPaused: Bool {
        if case .paused = entry?.state { return true }
        return false
    }

    private var failureReason: String? {
        if case .failed(let reason) = entry?.state { return reason }
        return nil
    }

    /// Real download bytes (summed file sizes), not the runtime-RAM estimate.
    private var downloadTotalBytes: Int64 {
        guard let entry else { return 0 }
        let b = entry.fit.diskBytes != 0 ? entry.fit.diskBytes : entry.manifest.estRuntimeBytes
        return Int64(max(b, max(entry.bytesDone, 1)))
    }

    private static let tips = [
        "Models stay completely on this device — nothing is uploaded.",
        "You can switch or download other models anytime in the Models tab.",
        "Pair your Mac anytime to run its larger models from your phone.",
    ]

    var body: some View {
        ViewThatFits(in: .vertical) {
            progress
            ScrollView { progress }
        }
        .task {
            // UI-55: `try? Task.sleep` swallows cancellation, so `while true`
            // spun hot (polling Core with no sleep) after the view went away.
            while !Task.isCancelled {
                let updated = core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
                    .first { $0.manifest.id == modelId }
                entry = updated
                if updated?.state == .installed {
                    onReady()
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private var progress: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer(minLength: PocketSpacing.s16)

            PocketMarkView(state: .loading, size: 72)

            VStack(spacing: PocketSpacing.s8) {
                Text("Downloading \(entry?.manifest.displayName ?? "model")…")
                    .font(.pocket(.display))
                    .foregroundStyle(PocketColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("This takes a few minutes. Stay on Wi-Fi if you can.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)

            if let reason = failureReason {
                VStack(spacing: PocketSpacing.s12) {
                    Text(reason == "network"
                         ? String(localized: "Download failed — check your connection.")
                         : String(localized: "Download failed (\(reason))."))
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.statusBad)
                        .multilineTextAlignment(.center)
                    // Side by side when they fit, stacked at large text sizes.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: PocketSpacing.s16) { failureButtons }
                        VStack(spacing: PocketSpacing.s12) { failureButtons }
                    }
                    if let retryError {
                        Text(retryError)
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, PocketSpacing.gutterIphone)
            } else if let entry {
                DownloadProgress(
                    state: isPaused
                        ? .paused(bytesDone: Int64(entry.bytesDone), bytesTotal: downloadTotalBytes)
                        : .downloading(
                            bytesDone: Int64(entry.bytesDone),
                            bytesTotal: downloadTotalBytes,
                            bytesPerSecond: 0 // no fabricated rate; honest instruments
                        ),
                    onPauseResume: {
                        // UI-140: say so when pause/resume fails, via the
                        // same line a failed Retry uses.
                        do {
                            if isPaused { try core.resumeDownload(modelId: modelId) }
                            else { try core.pauseDownload(modelId: modelId) }
                            retryError = nil
                        } catch {
                            retryError = error.localizedDescription
                        }
                    },
                    onCancel: {
                        do {
                            try core.cancelDownload(modelId: modelId)
                            onBack()
                        } catch {
                            retryError = error.localizedDescription
                        }
                    }
                )
                .padding(.horizontal, PocketSpacing.gutterIphone)
                if let retryError {
                    Text(retryError)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusBad)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, PocketSpacing.gutterIphone)
                }
            }

            if let onSkipToApple {
                Button("Try Apple's model while you wait", action: onSkipToApple)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }

            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                ForEach(Self.tips, id: \.self) { tip in
                    HStack(alignment: .top, spacing: PocketSpacing.s8) {
                        Image(systemName: "checkmark")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.accent)
                            .padding(.top, PocketSpacing.s2)
                            .accessibilityHidden(true)
                        Text(tip)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
            .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
            .padding(.horizontal, PocketSpacing.gutterIphone)

            Spacer(minLength: PocketSpacing.s16)
        }
        .padding(.vertical, PocketSpacing.s32)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var failureButtons: some View {
        Button {
            retryError = nil
            do {
                try core.startDownload(modelId: modelId)
            } catch {
                retryError = error.localizedDescription
            }
        } label: {
            // Explicit on-accent text: the default white fails contrast on
            // the dark-mode green fill.
            Text("Retry").foregroundStyle(PocketColor.accentOnAccent)
        }
        .buttonStyle(.borderedProminent)
        .tint(PocketColor.accent)
        Button("Choose another model") { onBack() }
            .buttonStyle(.bordered)
            .tint(PocketColor.accent)
    }
}

// MARK: - Ready View

private struct OnboardingReadyView: View {
    /// nil = plain start; a string = start a chat with that suggestion sent.
    let onStart: (String?) -> Void

    private static let suggestions = FirstChatSuggestion.all

    var body: some View {
        ViewThatFits(in: .vertical) {
            ready
            ScrollView { ready }
        }
    }

    private var ready: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer(minLength: PocketSpacing.s24)

            PocketMarkView(state: .idle, size: 80)

            VStack(spacing: PocketSpacing.s8) {
                Text("You're ready")
                    .font(.pocket(.display))
                    .foregroundStyle(PocketColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Everything is set up to run entirely on this iPhone.")
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)

            VStack(spacing: PocketSpacing.s12) {
                ForEach(Self.suggestions, id: \.title) { suggestion in
                    let title = suggestion.title, icon = suggestion.icon
                    Button(action: { onStart(suggestion.prompt) }) {
                        HStack(spacing: PocketSpacing.s12) {
                            Image(systemName: icon)
                                .font(.pocket(.callout))
                                .foregroundStyle(PocketColor.accent)
                                .frame(width: PocketSpacing.s24)
                                .accessibilityHidden(true)
                            Text(title)
                                .font(.pocket(.callout))
                                .foregroundStyle(PocketColor.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, PocketSpacing.s16)
                        .padding(.vertical, PocketSpacing.s12)
                        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
                        .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)

            Spacer(minLength: PocketSpacing.s24)

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onStart(nil)
            } label: {
                Text("Start chatting")
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.accentOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PocketSpacing.s12)
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketColor.accent)
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.bottom, PocketSpacing.s16)
        }
        .frame(maxWidth: .infinity)
    }
}
