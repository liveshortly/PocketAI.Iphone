import SwiftUI
import MessageUI
import PocketUI

/// UIViewControllerRepresentable wrapper around MFMailComposeViewController.
public struct MailComposeView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    public let recipients: [String]
    public let subject: String
    public let body: String
    public let attachmentData: Data?
    public let attachmentMimeType: String
    public let attachmentFileName: String

    public init(
        recipients: [String],
        subject: String,
        body: String,
        attachmentData: Data? = nil,
        attachmentMimeType: String = "application/json",
        attachmentFileName: String = "diagnostics.json"
    ) {
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.attachmentData = attachmentData
        self.attachmentMimeType = attachmentMimeType
        self.attachmentFileName = attachmentFileName
    }

    public func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients(recipients)
        composer.setSubject(subject)
        composer.setMessageBody(body, isHTML: false)
        if let attachmentData {
            composer.addAttachmentData(
                attachmentData,
                mimeType: attachmentMimeType,
                fileName: attachmentFileName
            )
        }
        return composer
    }

    public func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    public final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        public func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            dismiss()
        }
    }
}

/// QA-11: Screen showing the exact JSON payload (pretty-printed, selectable)
/// with a "Send…" button that opens Mail compose pre-filled with the diagnostics JSON,
/// or a "Copy to clipboard" fallback if Mail is not configured.
public struct DiagnosticsPreviewView: View {
    @State private var report: DiagnosticsReport
    @State private var jsonPayload: String
    @State private var showMailComposer = false
    @State private var showCopiedBanner = false

    public init(report: DiagnosticsReport = DiagnosticsReport.current()) {
        _report = State(initialValue: report)
        _jsonPayload = State(initialValue: report.toPrettyJSON())
    }

    private var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                // Info callout card
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Label("Review diagnostic report", systemImage: "shield.lefthalf.filled")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.accent)

                    Text("PocketAI does not send diagnostics automatically. You can review the exact payload below before choosing to send it to support via email. No chat content, prompts, or sensitive keys are included.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                }
                .padding(PocketSpacing.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PocketColor.bgSurface, in: RoundedRectangle(cornerRadius: PocketSpacing.s12))

                if !canSendMail {
                    HStack(spacing: PocketSpacing.s12) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(PocketColor.statusWarn)
                        Text("Apple Mail is not configured on this device. You can copy the report and email it manually to support@pocket.liveshortly.com.")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                    .padding(PocketSpacing.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PocketColor.bgSurface, in: RoundedRectangle(cornerRadius: PocketSpacing.s8))
                    .accessibilityLabel("Apple Mail not configured notice")
                }

                if showCopiedBanner {
                    HStack(spacing: PocketSpacing.s8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(PocketColor.statusOk)
                        Text("Diagnostic report copied to clipboard.")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textPrimary)
                    }
                    .padding(PocketSpacing.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PocketColor.bgSurface, in: RoundedRectangle(cornerRadius: PocketSpacing.s8))
                    .transition(.opacity)
                }

                // JSON Payload preview
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    HStack {
                        Text("DIAGNOSTICS PAYLOAD")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textTertiary)
                        Spacer()
                        Button {
                            copyToClipboard()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.pocket(.caption))
                        }
                        .accessibilityLabel("Copy JSON payload to clipboard")
                        .foregroundStyle(PocketColor.accent)
                    }

                    Text(jsonPayload)
                        .font(.pocket(.mono))
                        .foregroundStyle(PocketColor.textPrimary)
                        .textSelection(.enabled)
                        .padding(PocketSpacing.s12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PocketColor.bgSunken, in: RoundedRectangle(cornerRadius: PocketSpacing.s8))
                        .accessibilityLabel("Diagnostic report JSON payload")
                }

                // Action button: Send… or Copy fallback
                VStack(spacing: PocketSpacing.s12) {
                    if canSendMail {
                        Button {
                            showMailComposer = true
                        } label: {
                            HStack {
                                Image(systemName: "paperplane.fill")
                                Text("Send…")
                            }
                            .font(.pocket(.headline))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, PocketSpacing.s12)
                            .background(PocketColor.accent, in: RoundedRectangle(cornerRadius: PocketSpacing.s8))
                            .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Send diagnostic report via Mail")
                    } else {
                        Button {
                            copyToClipboard()
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.doc")
                                Text("Copy to clipboard")
                            }
                            .font(.pocket(.headline))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, PocketSpacing.s12)
                            .background(PocketColor.accent, in: RoundedRectangle(cornerRadius: PocketSpacing.s8))
                            .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Copy diagnostic report to clipboard")
                    }
                }
                .padding(.top, PocketSpacing.s8)
            }
            .padding(PocketSpacing.s16)
        }
        .background(PocketColor.bgCanvas)
        .navigationTitle("Diagnostic Report")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMailComposer) {
            MailComposeView(
                recipients: ["support@pocket.liveshortly.com"],
                subject: "PocketAI Diagnostic Report",
                body: jsonPayload,
                attachmentData: jsonPayload.data(using: .utf8),
                attachmentMimeType: "application/json",
                attachmentFileName: "diagnostics.json"
            )
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = jsonPayload
        withAnimation {
            showCopiedBanner = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation {
                showCopiedBanner = false
            }
        }
    }
}
