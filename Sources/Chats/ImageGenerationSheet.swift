import SwiftUI
import Photos
import PocketKit
import PocketUI
import PocketImageGen

/// UI-18: Image generation view model managing SDXL-Turbo generation,
/// live per-step previews, cancellation, and save/share actions.
@Observable
@MainActor
final class ImageGenSheetViewModel {
    enum State: Equatable {
        case idle
        case loadingModel
        case generating(current: Int, total: Int)
        case completed
        case error(String)
    }

    var prompt: String
    var size: Int = 512
    var steps: Int = 2
    var state: State = .idle
    var previewImage: UIImage?
    var finalImage: UIImage?
    var isSavedToPhotos = false
    var photoLibraryPermissionDenied = false
    var photoSaveErrorMessage: String?
    var generatedFileURL: URL?

    private var currentTask: Task<Void, Never>?
    private var generator: PocketImageGenerator?
    private let core: CoreClient

    init(prompt: String = "", core: CoreClient) {
        self.prompt = prompt
        self.core = core
    }

    var isBusy: Bool {
        switch state {
        case .loadingModel, .generating:
            return true
        case .idle, .completed, .error:
            return false
        }
    }

    func startGeneration() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        currentTask?.cancel()
        cleanupTempFile()
        previewImage = nil
        finalImage = nil
        isSavedToPhotos = false
        photoSaveErrorMessage = nil
        photoLibraryPermissionDenied = false
        state = .loadingModel

        let requestedSize = size
        let requestedSteps = steps

        currentTask = Task { [weak self] in
            guard let self else { return }

            // ponytail: needs an installed-image-model-path accessor on CoreClient
            guard let modelDir = self.resolveInstalledModelDirectory() else {
                self.state = .error("No image model installed — install one in Models")
                return
            }

            let gen = PocketImageGenerator(conserveMemory: true)
            self.generator = gen

            do {
                try await gen.load(modelDirectory: modelDir)
            } catch {
                if Task.isCancelled { return }
                self.state = .error("No image model installed — install one in Models")
                return
            }

            if Task.isCancelled { return }
            self.state = .generating(current: 0, total: requestedSteps)

            do {
                let cgImage = try await gen.generate(
                    prompt: trimmedPrompt,
                    negativePrompt: nil,
                    size: requestedSize,
                    steps: requestedSteps,
                    seed: nil
                ) { [weak self] current, total, previewCG in
                    Task { @MainActor [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        self.state = .generating(current: current, total: total)
                        if let previewCG {
                            self.previewImage = UIImage(cgImage: previewCG)
                        }
                    }
                }

                if Task.isCancelled { return }
                let resultImage = UIImage(cgImage: cgImage)
                self.finalImage = resultImage
                self.previewImage = resultImage
                self.persistTempImage(resultImage)
                self.state = .completed
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                if Task.isCancelled {
                    self.state = .idle
                    return
                }
                if let genErr = error as? ImageGenError {
                    switch genErr {
                    case .cancelled:
                        self.state = .idle
                        return
                    case .modelNotFound, .notLoaded:
                        self.state = .error("No image model installed — install one in Models")
                        return
                    default:
                        break
                    }
                }
                self.state = .error(error.localizedDescription)
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        Task {
            await generator?.unload()
            generator = nil
        }
        state = .idle
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func saveToPhotos() {
        guard let finalImage else { return }

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            switch status {
            case .authorized, .limited:
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: finalImage)
                    }
                    self.isSavedToPhotos = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch {
                    self.photoSaveErrorMessage = "Failed to save: \(error.localizedDescription)"
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            case .denied, .restricted:
                self.photoLibraryPermissionDenied = true
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    private func resolveInstalledModelDirectory() -> URL? {
        // ponytail: needs an installed-image-model-path accessor on CoreClient
        let catalog = core.catalog(filter: CatalogFilter(modality: .image, curatedOnly: false, installedOnly: true))
        guard let entry = catalog.first(where: { $0.state == .installed }) else {
            return nil
        }
        if let liveCore = core as? LiveCore,
           let plan = try? liveCore.rawCore.planDownload(id: entry.manifest.id) {
            let candidate = URL(fileURLWithPath: plan.destDir)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func persistTempImage(_ image: UIImage) {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("gen-\(UUID().uuidString).png")
        if let data = image.pngData() {
            try? data.write(to: fileURL)
            self.generatedFileURL = fileURL
        }
    }

    func cleanupTempFile() {
        if let url = generatedFileURL {
            try? FileManager.default.removeItem(at: url)
            generatedFileURL = nil
        }
    }
}

/// UI-18: Image generation prompt sheet (`02` §7, UI-18).
/// Offers prompt entry, size selector (512 / 768 / 1024), step stepper (1...4),
/// live stepwise preview, save-to-photos, share, and graceful degradation
/// when no image model is installed.
struct ImageGenerationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: ImageGenSheetViewModel
    var onAttachToChat: ((UIImage, URL) -> Void)?
    @ScaledMetric(relativeTo: .body) private var previewPlaceholderHeight: CGFloat = 200

    /// Label-beside-control rows run side by side until the text is large
    /// enough that the control would clip, then stack. Same children, so no
    /// duplicated view bodies.
    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PocketSpacing.s8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: PocketSpacing.s12))
    }

    init(prompt: String = "", core: CoreClient, onAttachToChat: ((UIImage, URL) -> Void)? = nil) {
        _viewModel = State(initialValue: ImageGenSheetViewModel(prompt: prompt, core: core))
        self.onAttachToChat = onAttachToChat
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PocketSpacing.s16) {
                    promptSection
                    parametersSection
                    actionSection
                    previewSection
                }
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.vertical, PocketSpacing.s16)
            }
            .background(PocketColor.bgCanvas)
            .navigationTitle("Generate Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if viewModel.isBusy {
                            viewModel.cancel()
                        }
                        viewModel.cleanupTempFile()
                        dismiss()
                    }
                    .accessibilityLabel("Close image generation")
                }
            }
            .alert("Photo Library Access Denied", isPresented: $viewModel.photoLibraryPermissionDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("PocketAI needs permission to save generated images to your photo library. You can grant access in Settings.")
            }
            .alert("Save Error", isPresented: Binding(
                get: { viewModel.photoSaveErrorMessage != nil },
                set: { if !$0 { viewModel.photoSaveErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                if let msg = viewModel.photoSaveErrorMessage {
                    Text(msg)
                }
            }
        }
    }

    // MARK: - Sections

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            Text("PROMPT")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textSecondary)

            TextField("Describe the image you want to generate…", text: $viewModel.prompt, axis: .vertical)
                .font(.pocket(.body))
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .padding(PocketSpacing.s12)
                .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(PocketColor.lineHairline, lineWidth: 1)
                )
                .disabled(viewModel.isBusy)
                .accessibilityLabel("Image prompt input")
        }
    }

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            rowLayout {
                Text("Size")
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textPrimary)
                // Takes whatever width is left instead of a fixed 220pt, so
                // the segments breathe on a big phone and don't clip "1024"
                // on a small one.
                Picker("Size", selection: $viewModel.size) {
                    Text("512").tag(512)
                    Text("768").tag(768)
                    Text("1024").tag(1024)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                .disabled(viewModel.isBusy)
                .accessibilityLabel("Image size picker")
            }

            Divider()

            rowLayout {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Steps")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text("Denoising iterations (1–4)")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Stepper(value: $viewModel.steps, in: 1...4) {
                    Text("\(viewModel.steps)")
                        .font(.pocket(.body))
                        .foregroundStyle(PocketColor.textPrimary)
                        .monospacedDigit()
                }
                .disabled(viewModel.isBusy)
                .accessibilityLabel("Generation steps")
                .accessibilityValue("\(viewModel.steps) steps")
            }
        }
        .padding(PocketSpacing.s12)
        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))
    }

    private var actionSection: some View {
        Group {
            if viewModel.isBusy {
                Button(action: { viewModel.cancel() }) {
                    HStack(spacing: PocketSpacing.s8) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Cancel Generation")
                    }
                    .font(.pocket(.body))
                    .foregroundStyle(PocketColor.statusBad)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PocketSpacing.s12)
                    .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(PocketColor.statusBad.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel image generation")
            } else {
                Button(action: { viewModel.startGeneration() }) {
                    HStack(spacing: PocketSpacing.s8) {
                        Image(systemName: "sparkles")
                        Text("Generate")
                    }
                    .font(.pocket(.body).bold())
                    .foregroundStyle(PocketColor.accentOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PocketSpacing.s12)
                    .background(
                        viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? PocketColor.textTertiary
                            : PocketColor.accent,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Generate image")
                .accessibilityHint("Starts on-device image generation with SDXL-Turbo")
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()

        case .loadingModel:
            VStack(spacing: PocketSpacing.s12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(PocketColor.accent)
                Text("Loading SDXL-Turbo model…")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, PocketSpacing.s24)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading image generation model")

        case .generating(let current, let total):
            VStack(spacing: PocketSpacing.s12) {
                if let preview = viewModel.previewImage {
                    Image(uiImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(PocketColor.lineHairline, lineWidth: 1)
                        )
                        .accessibilityLabel("Live image preview step \(current) of \(total)")
                } else {
                    // Fills the card's width whatever the device, and the
                    // reserved height follows the text size.
                    ProgressView()
                        .controlSize(.large)
                        .tint(PocketColor.accent)
                        .frame(maxWidth: .infinity, minHeight: previewPlaceholderHeight)
                }

                HStack(spacing: PocketSpacing.s8) {
                    ProgressView(value: Double(current), total: Double(total))
                        .tint(PocketColor.accent)
                    Text("Step \(current)/\(total)")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(PocketSpacing.s12)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))

        case .completed:
            if let image = viewModel.finalImage {
                VStack(spacing: PocketSpacing.s16) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(PocketColor.lineHairline, lineWidth: 1)
                        )
                        .accessibilityLabel("Generated image for \(viewModel.prompt)")

                    VStack(spacing: PocketSpacing.s8) {
                        rowLayout {
                            Button(action: { viewModel.saveToPhotos() }) {
                                HStack(spacing: PocketSpacing.s4) {
                                    Image(systemName: viewModel.isSavedToPhotos ? "checkmark.circle.fill" : "square.and.arrow.down")
                                    Text(viewModel.isSavedToPhotos ? "Saved" : "Save to Photos")
                                }
                                .font(.pocket(.callout))
                                .foregroundStyle(viewModel.isSavedToPhotos ? PocketColor.statusOk : PocketColor.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, PocketSpacing.s8)
                                .background(PocketColor.bgCanvas, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isSavedToPhotos)
                            .accessibilityLabel(viewModel.isSavedToPhotos ? "Image saved to Photos" : "Save image to Photos")

                            ShareLink(
                                item: Image(uiImage: image),
                                preview: SharePreview(viewModel.prompt, image: Image(uiImage: image))
                            ) {
                                HStack(spacing: PocketSpacing.s4) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Share")
                                }
                                .font(.pocket(.callout))
                                .foregroundStyle(PocketColor.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, PocketSpacing.s8)
                                .background(PocketColor.bgCanvas, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Share generated image")
                        }

                        if let onAttachToChat, let url = viewModel.generatedFileURL {
                            Button(action: {
                                onAttachToChat(image, url)
                                dismiss()
                            }) {
                                HStack(spacing: PocketSpacing.s4) {
                                    Image(systemName: "paperplane")
                                    Text("Attach to Chat")
                                }
                                .font(.pocket(.callout))
                                .foregroundStyle(PocketColor.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, PocketSpacing.s8)
                                .background(PocketColor.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Attach generated image to chat message")
                        }
                    }
                }
                .padding(PocketSpacing.s12)
                .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))
            }

        case .error(let error):
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                HStack(spacing: PocketSpacing.s8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PocketColor.statusBad)
                    Text(error)
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.statusBad)
                }
                Button("Try Again") {
                    viewModel.startGeneration()
                }
                .font(.pocket(.footnote).bold())
                .foregroundStyle(PocketColor.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PocketSpacing.s12)
            .background(PocketColor.bgSunken, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Generation error: \(error)")
        }
    }
}

#Preview("Light - Idle") {
    ImageGenerationSheet(prompt: "A neon cyberpunk street at night", core: PreviewCore())
}

#Preview("Dark - Idle") {
    ImageGenerationSheet(prompt: "A neon cyberpunk street at night", core: PreviewCore())
        .preferredColorScheme(.dark)
}

#Preview("AX3") {
    ImageGenerationSheet(prompt: "A neon cyberpunk street at night", core: PreviewCore())
        .environment(\.dynamicTypeSize, .accessibility3)
}

/// Largest text size: the label/control rows must stack rather than clip.
#Preview("AX5") {
    ImageGenerationSheet(prompt: "A neon cyberpunk street at night", core: PreviewCore())
        .environment(\.dynamicTypeSize, .accessibility5)
}
