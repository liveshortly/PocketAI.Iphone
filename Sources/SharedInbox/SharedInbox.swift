import Foundation

public enum SharedInboxItemKind: String, Codable, Sendable {
    case text
    case url
    case pdf
    case image

    /// The raw value is persisted in the inbox JSON, so the badge needs its
    /// own label; rendering the raw value left it untranslatable.
    public var displayName: String {
        switch self {
        case .text: String(localized: "TEXT")
        case .url: String(localized: "URL")
        case .pdf: String(localized: "PDF")
        case .image: String(localized: "IMAGE")
        }
    }
}

public struct SharedInboxItem: Codable, Identifiable, Sendable {
    public let id: String
    public let kind: SharedInboxItemKind
    public let filename: String
    public let originalName: String
    public let addedAt: Date
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, filename, originalName, addedAt, note
    }

    public init(
        id: String = UUID().uuidString,
        kind: SharedInboxItemKind,
        filename: String,
        originalName: String? = nil,
        addedAt: Date = Date(),
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.originalName = originalName ?? filename
        self.addedAt = addedAt
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(SharedInboxItemKind.self, forKey: .kind)
        self.filename = try container.decode(String.self, forKey: .filename)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? (self.filename as NSString).deletingPathExtension
        self.originalName = try container.decodeIfPresent(String.self, forKey: .originalName) ?? self.filename
        self.addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

public enum SharedInbox {
    public static let appGroupId = "group.com.getpocketai.app"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    public static var inboxURL: URL? {
        containerURL?.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Ensure the Inbox directory exists.
    public static func ensureInboxDirectoryExists() throws -> URL {
        guard let url = inboxURL else {
            throw SharedInboxError.appGroupUnavailable
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Writes an item payload and its JSON sidecar into the Inbox.
    public static func saveItem(
        kind: SharedInboxItemKind,
        originalName: String,
        data: Data,
        preferredExtension: String?,
        note: String? = nil
    ) throws -> SharedInboxItem {
        let inbox = try ensureInboxDirectoryExists()
        let id = UUID().uuidString
        let ext = preferredExtension ?? defaultExtension(for: kind)
        let payloadFilename = "\(id).\(ext)"
        let sidecarFilename = "\(id).json"

        let payloadURL = inbox.appendingPathComponent(payloadFilename)
        let sidecarURL = inbox.appendingPathComponent(sidecarFilename)

        try data.write(to: payloadURL, options: .atomic)

        let item = SharedInboxItem(
            id: id,
            kind: kind,
            filename: payloadFilename,
            originalName: originalName,
            addedAt: Date(),
            note: note
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sidecarData = try encoder.encode(item)
        try sidecarData.write(to: sidecarURL, options: .atomic)

        return item
    }

    /// Lists all items in the Inbox.
    public static func listItems() -> [SharedInboxItem] {
        guard let inbox = inboxURL, FileManager.default.fileExists(atPath: inbox.path) else {
            return []
        }
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var items: [SharedInboxItem] = []

        for file in files where file.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: file),
               let item = try? decoder.decode(SharedInboxItem.self, from: data) {
                items.append(item)
            }
        }

        return items.sorted(by: { $0.addedAt < $1.addedAt })
    }

    /// Get payload URL for an item.
    public static func payloadURL(for item: SharedInboxItem) -> URL? {
        inboxURL?.appendingPathComponent(item.filename)
    }

    /// Removes an item's payload and sidecar.
    public static func deleteItem(_ item: SharedInboxItem) {
        guard let inbox = inboxURL else { return }
        let payloadURL = inbox.appendingPathComponent(item.filename)
        let sidecarURL = inbox.appendingPathComponent("\(item.id).json")
        try? FileManager.default.removeItem(at: payloadURL)
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    private static func defaultExtension(for kind: SharedInboxItemKind) -> String {
        switch kind {
        case .text, .url:
            return "txt"
        case .pdf:
            return "pdf"
        case .image:
            return "jpg"
        }
    }
}

public enum SharedInboxError: LocalizedError {
    case appGroupUnavailable
    case payloadNotFound

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return String(localized: "Shared app group container is not available.")
        case .payloadNotFound:
            return String(localized: "Shared item payload file not found.")
        }
    }
}
