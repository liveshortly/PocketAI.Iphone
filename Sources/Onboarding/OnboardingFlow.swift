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

    public init(core: CoreClient, deviceProfile: DeviceProfile, onFinished: @escaping () -> Void) {
        self.core = core
        self.deviceProfile = deviceProfile
        self.onFinished = onFinished
    }

    public var body: some View {
        Group {
            switch step {
            case .welcome:
                OnboardingWelcomeView {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        step = .deviceCheck
                    }
                }
            case .deviceCheck:
                OnboardingDeviceCheckView(profile: deviceProfile) {
                    catalog = core.catalog(filter: CatalogFilter(modality: .text, curatedOnly: true, installedOnly: false))
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        step = .pickModel
                    }
                }
            case .pickModel:
                OnboardingPickModelView(catalog: catalog) { modelId in
                    selectedModelId = modelId
                    if let modelId, modelId != AppleFoundationModelsEngine.modelId {
                        try? core.startDownload(modelId: modelId)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            step = .downloading
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            step = .ready
                        }
                    }
                }
            case .downloading:
                OnboardingDownloadingView(
                    core: core,
                    modelId: selectedModelId ?? "",
                    onSkipToApple: AppleFoundationModelsEngine.isAvailable ? {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            step = .ready
                        }
                    } : nil,
                    onReady: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            step = .ready
                        }
                    }
                )
            case .ready:
                OnboardingReadyView(onStart: onFinished)
            }
        }
        .animation(.default, value: step)
        .background(PocketColor.bgCanvas)
    }
}

// MARK: - Welcome View

private struct OnboardingWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: PocketSpacing.s24) {
                Spacer(minLength: 20)

                PocketMarkView(state: .working(tokPerSec: 32), size: 96)
                    .padding(.bottom, PocketSpacing.s8)

                VStack(spacing: PocketSpacing.s8) {
                    Text("Private AI that lives on your devices.")
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(PocketColor.textPrimary)

                    Text("Run modern open-weights models locally on Apple Silicon. Zero cloud, zero accounts, completely offline.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, PocketSpacing.s12)
                }

                VStack(spacing: PocketSpacing.s12) {
                    benefitCard(
                        icon: "iphone.gen3",
                        title: "Runs on this iPhone, even offline",
                        subtitle: "Inference executes locally via Metal and MLX."
                    )
                    benefitCard(
                        icon: "lock.shield.fill",
                        title: "Nothing leaves your device",
                        subtitle: "Verify every socket live in Network Proof."
                    )
                    benefitCard(
                        icon: "laptopcomputer",
                        title: "Use your Mac's bigger models",
                        subtitle: "Pair over local Wi-Fi to tap into your Mac's unified memory."
                    )
                }
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.vertical, PocketSpacing.s8)

                Spacer(minLength: 20)

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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PocketColor.accentSoft)
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PocketColor.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)
                Text(subtitle)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    private var rows: [String] {
        var r = [
            "\(profile.chip) · \(formatBytes(profile.totalRamBytes)) memory · up to \(formatBytes(profile.appMemoryLimitBytes)) for models",
            "\(formatBytes(profile.freeDiskBytes)) free storage",
        ]
        if AppleFoundationModelsEngine.isAvailable {
            r.append("Apple Intelligence available")
        }
        return r
    }

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(PocketColor.accentSoft)
                    .frame(width: 72, height: 72)
                PocketMarkView(state: .loading, size: 40)
            }

            Text("Checking your device")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(PocketColor.textPrimary)

            VStack(spacing: PocketSpacing.s12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index < revealedRows {
                        HStack(spacing: PocketSpacing.s12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(PocketColor.statusOk)
                            Text(row)
                                .font(.pocket(.body))
                                .foregroundStyle(PocketColor.textPrimary)
                            Spacer()
                        }
                        .padding(PocketSpacing.s12)
                        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
                        .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)

            Spacer()

            Text("We read this on your device. It is never sent anywhere.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.bottom, PocketSpacing.s24)
        }
        .task {
            for _ in rows {
                try? await Task.sleep(nanoseconds: 280_000_000)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation { revealedRows += 1 }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            onContinue()
        }
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

    private var alternates: [CatalogEntry] {
        catalog.filter { $0.manifest.id != recommended?.manifest.id }.prefix(2).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: PocketSpacing.s24) {
                VStack(spacing: PocketSpacing.s8) {
                    Text("Pick your first model")
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundStyle(PocketColor.textPrimary)

                    Text("We test fit on your device before downloading.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                }
                .padding(.top, PocketSpacing.s16)

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
                                sizeOnDisk: formatBytes(recommended.manifest.estRuntimeBytes),
                                speedText: recommended.fit.estTokensPerSec.map { "\(Int($0)) tok/s" },
                                speedIsMeasured: false,
                                licenseLabel: recommended.manifest.license.spdx
                            ),
                            primaryActionLabel: "Download \(formatBytes(recommended.manifest.estRuntimeBytes))",
                            onPrimaryAction: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onPick(recommended.manifest.id)
                            }
                        )
                        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PocketColor.lineHairline))

                        HStack(spacing: 4) {
                            Image(systemName: "wifi")
                                .font(.caption2)
                            Text("Wi-Fi recommended")
                                .font(.pocket(.caption))
                        }
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
                                    sizeOnDisk: formatBytes(entry.manifest.estRuntimeBytes),
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
                            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PocketColor.lineHairline))
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
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(PocketColor.bgSunken)
                        .frame(width: 40, height: 40)
                    Image(systemName: "apple.logo")
                        .font(.system(size: 20))
                        .foregroundStyle(PocketColor.textPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start instantly with Apple Intelligence")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text("No download required · Built into iOS")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PocketColor.lineHairline))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Downloading View

private struct OnboardingDownloadingView: View {
    let core: CoreClient
    let modelId: String
    let onSkipToApple: (() -> Void)?
    let onReady: () -> Void

    @State private var entry: CatalogEntry?

    private static let tips = [
        "Models stay completely on this device — nothing is uploaded.",
        "You can switch or download other models anytime in the Models tab.",
        "Pair your Mac anytime to use its larger 70B+ models too.",
    ]

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()

            PocketMarkView(state: .loading, size: 72)

            VStack(spacing: PocketSpacing.s8) {
                Text("Downloading \(entry?.manifest.displayName ?? "model")…")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(PocketColor.textPrimary)

                Text("Setting up on-device neural weights")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }

            if let entry {
                DownloadProgress(
                    state: .downloading(
                        bytesDone: Int64(entry.bytesDone),
                        bytesTotal: Int64(entry.manifest.estRuntimeBytes),
                        bytesPerSecond: 18_000_000
                    ),
                    onPauseResume: {},
                    onCancel: {}
                )
                .padding(.horizontal, PocketSpacing.gutterIphone)
            }

            if let onSkipToApple {
                Button("Try Apple's model while you wait", action: onSkipToApple)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.accent)
            }

            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                ForEach(Self.tips, id: \.self) { tip in
                    HStack(alignment: .top, spacing: PocketSpacing.s8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(PocketColor.accent)
                            .padding(.top, 3)
                        Text(tip)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                }
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PocketColor.lineHairline))
            .padding(.horizontal, PocketSpacing.gutterIphone)

            Spacer()
        }
        .padding(.vertical, PocketSpacing.s32)
        .task {
            while true {
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
}

// MARK: - Ready View

private struct OnboardingReadyView: View {
    let onStart: () -> Void

    private static let suggestions = [
        ("Summarize a long email", "doc.text"),
        ("Explain a concept simply", "lightbulb"),
        ("Draft a quick reply", "bubble.left.and.text.bubble.right"),
    ]

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()

            PocketMarkView(state: .idle, size: 80)

            VStack(spacing: PocketSpacing.s8) {
                Text("You're ready")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(PocketColor.textPrimary)

                Text("Everything is set up to run entirely on this iPhone.")
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: PocketSpacing.s12) {
                ForEach(Self.suggestions, id: \.0) { title, icon in
                    Button(action: onStart) {
                        HStack(spacing: PocketSpacing.s12) {
                            Image(systemName: icon)
                                .font(.system(size: 15))
                                .foregroundStyle(PocketColor.accent)
                                .frame(width: 24)
                            Text(title)
                                .font(.pocket(.callout))
                                .foregroundStyle(PocketColor.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(PocketColor.textTertiary)
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

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onStart()
            } label: {
                Text("Start chatting")
                    .font(.pocket(.headline))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PocketSpacing.s12)
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketColor.accent)
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.bottom, PocketSpacing.s16)
        }
    }
}
