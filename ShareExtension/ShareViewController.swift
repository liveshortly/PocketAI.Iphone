import UIKit
import Social
import UniformTypeIdentifiers

@objc(ShareViewController)
class ShareViewController: SLComposeServiceViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add to PocketAI"
        placeholder = "Optional note or instructions..."
    }

    override func isContentValid() -> Bool {
        true
    }

    override func configurationItems() -> [Any]! {
        []
    }

    override func didSelectCancel() {
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: "com.getpocketai.ShareExtension",
                code: NSUserCancelledError,
                userInfo: nil
            )
        )
    }

    override func didSelectPost() {
        Task { @MainActor in
            do {
                try await saveSharedItems()
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                self.extensionContext?.cancelRequest(withError: error)
            }
        }
    }

    // MARK: - Saving Items

    private func saveSharedItems() async throws {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return
        }

        let note = contentText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userNote = (note?.isEmpty == false) ? note : nil

        let providers = extensionItems.compactMap { $0.attachments }.flatMap { $0 }
        var savedCount = 0

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                if let result = try await loadItemData(from: provider, forTypeIdentifier: UTType.pdf.identifier) {
                    let name = result.originalName ?? "Document.pdf"
                    _ = try SharedInbox.saveItem(
                        kind: .pdf,
                        originalName: name,
                        data: result.data,
                        preferredExtension: "pdf",
                        note: userNote
                    )
                    savedCount += 1
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let result = try await loadItemData(from: provider, forTypeIdentifier: UTType.image.identifier) {
                    let ext = result.ext ?? "jpg"
                    let name = result.originalName ?? "Image.\(ext)"
                    _ = try SharedInbox.saveItem(
                        kind: .image,
                        originalName: name,
                        data: result.data,
                        preferredExtension: ext,
                        note: userNote
                    )
                    savedCount += 1
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let result = try await loadItemData(from: provider, forTypeIdentifier: UTType.fileURL.identifier) {
                    let ext = result.ext ?? "dat"
                    let name = result.originalName ?? "File.\(ext)"
                    let kind: SharedInboxItemKind
                    if ext == "pdf" {
                        kind = .pdf
                    } else if ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(ext) {
                        kind = .image
                    } else {
                        kind = .text
                    }
                    _ = try SharedInbox.saveItem(
                        kind: kind,
                        originalName: name,
                        data: result.data,
                        preferredExtension: ext,
                        note: userNote
                    )
                    savedCount += 1
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let result = try await loadWebURL(from: provider) {
                    if let data = result.urlString.data(using: .utf8) {
                        let name = result.title ?? "Web Link"
                        _ = try SharedInbox.saveItem(
                            kind: .url,
                            originalName: name,
                            data: data,
                            preferredExtension: "txt",
                            note: userNote
                        )
                        savedCount += 1
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                if let text = try await loadText(from: provider), let data = text.data(using: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let firstLine = trimmed.components(separatedBy: .newlines).first ?? ""
                    let preview = String(firstLine.prefix(30))
                    let name = preview.isEmpty ? "Shared Text" : "\(preview)..."
                    _ = try SharedInbox.saveItem(
                        kind: .text,
                        originalName: name,
                        data: data,
                        preferredExtension: "txt",
                        note: userNote
                    )
                    savedCount += 1
                }
            }
        }

        // If no attachments were saved, but user typed into the compose sheet, save as text note
        if savedCount == 0, let userNote, let data = userNote.data(using: .utf8) {
            _ = try SharedInbox.saveItem(
                kind: .text,
                originalName: "Shared Note",
                data: data,
                preferredExtension: "txt",
                note: nil
            )
        }
    }

    // MARK: - Asynchronous Item Loading Helpers

    private func loadItemData(
        from provider: NSItemProvider,
        forTypeIdentifier typeIdentifier: String
    ) async throws -> (data: Data, originalName: String?, ext: String?)? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = (item as? URL) ?? (item as? NSURL as URL?) {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    do {
                        let data = try Data(contentsOf: url)
                        let name = url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
                        let ext = url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased()
                        continuation.resume(returning: (data, name, ext))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else if let data = (item as? Data) ?? (item as? NSData as Data?) {
                    continuation.resume(returning: (data, nil, nil))
                } else if let image = item as? UIImage {
                    if let data = image.jpegData(compressionQuality: 0.9) {
                        continuation.resume(returning: (data, nil, "jpg"))
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else if let string = (item as? String) ?? (item as? NSString as String?) {
                    if let data = string.data(using: .utf8) {
                        continuation.resume(returning: (data, nil, "txt"))
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadWebURL(from provider: NSItemProvider) async throws -> (urlString: String, title: String?)? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = (item as? URL) ?? (item as? NSURL as URL?) {
                    if url.isFileURL {
                        continuation.resume(returning: nil)
                    } else {
                        let host = url.host ?? url.absoluteString
                        continuation.resume(returning: (url.absoluteString, host))
                    }
                } else if let str = (item as? String) ?? (item as? NSString as String?) {
                    continuation.resume(returning: (str, "Web Link"))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async throws -> String? {
        let typeId = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            ? UTType.plainText.identifier
            : UTType.text.identifier

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let str = (item as? String) ?? (item as? NSString as String?) {
                    continuation.resume(returning: str)
                } else if let data = (item as? Data) ?? (item as? NSData as Data?),
                          let str = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: str)
                } else if let url = (item as? URL) ?? (item as? NSURL as URL?) {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let str = try? String(contentsOf: url, encoding: .utf8)
                    continuation.resume(returning: str)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
