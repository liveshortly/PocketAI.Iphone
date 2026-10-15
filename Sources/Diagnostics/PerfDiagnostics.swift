#if DEBUG
import Foundation
import UIKit
import Darwin
import PocketKit

/// QA-05: In-app performance diagnostics collector & CSV exporter.
///
/// Collects Time To First Token (TTFT), decode tokens/second, peak physical
/// memory footprint (`task_vm_info.phys_footprint`), available process memory delta
/// (`os_proc_available_memory`), and thermal state (`ProcessInfo.thermalState`).
/// Exposes metrics via accessibility identifiers for XCUITest automation and appends
/// formatted rows to sandbox CSV `perf/<date>-<device>.csv`.
@Observable
@MainActor
public final class PerfDiagnostics {
    public static let shared = PerfDiagnostics()
    public static let launchArgument = "-PocketPerfDiagnostics"

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    public struct GenerationPerfRecord: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let device: String
        public let model: String
        public let ttftMs: Double
        public let decodeTps: Double
        public let peakMemMB: Double
        public let availableMemDeltaMB: Double
        public let thermal: String

        public var csvRow: String {
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withInternetDateTime]
            let dateStr = df.string(from: date)
            return "\(dateStr),\(device),\(model),\(String(format: "%.1f", ttftMs)),\(String(format: "%.1f", decodeTps)),\(String(format: "%.2f", peakMemMB)),\(thermal)\n"
        }
    }

    public private(set) var latestRecord: GenerationPerfRecord?
    private var startAvailableMemBytes: UInt64 = 0

    public func startGeneration() {
        let mem = os_proc_available_memory()
        startAvailableMemBytes = mem > 0 ? UInt64(mem) : 0
    }

    @discardableResult
    public func recordGeneration(
        model: String,
        stats: GenerateStats?,
        fallbackTtftMs: Double = 0,
        fallbackDecodeTps: Double = 0
    ) -> GenerationPerfRecord {
        let ttft = stats.map { Double($0.ttftMs) } ?? fallbackTtftMs
        let tps = stats.map { Double($0.decodeTps) } ?? fallbackDecodeTps

        let physFootprintBytes = Self.currentPhysicalFootprintBytes()
        let peakMemMB = Double(physFootprintBytes) / (1024.0 * 1024.0)

        let endMem = os_proc_available_memory()
        let endAvailableBytes: UInt64 = endMem > 0 ? UInt64(endMem) : 0
        let availDeltaMB: Double
        if startAvailableMemBytes > 0 {
            availDeltaMB = Double(Int64(startAvailableMemBytes) - Int64(endAvailableBytes)) / (1024.0 * 1024.0)
        } else {
            availDeltaMB = 0
        }

        let thermal = Self.thermalStateString(ProcessInfo.processInfo.thermalState)
        let device = Self.deviceIdentifier()

        let record = GenerationPerfRecord(
            date: Date(),
            device: device,
            model: model,
            ttftMs: ttft,
            decodeTps: tps,
            peakMemMB: peakMemMB,
            availableMemDeltaMB: availDeltaMB,
            thermal: thermal
        )

        self.latestRecord = record
        _ = try? Self.appendCSVRow(record)
        return record
    }

    public static func currentPhysicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        return (kr == KERN_SUCCESS) ? UInt64(info.phys_footprint) : 0
    }

    public static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    public static func deviceIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? (UIDevice.current.name.replacingOccurrences(of: " ", with: "_")) : identifier
    }

    @discardableResult
    public static func appendCSVRow(
        _ record: GenerationPerfRecord,
        fileManager: FileManager = .default
    ) throws -> URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let perfDir = documentsURL.appendingPathComponent("perf", isDirectory: true)
        if !fileManager.fileExists(atPath: perfDir.path) {
            try fileManager.createDirectory(at: perfDir, withIntermediateDirectories: true)
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dayStr = dayFormatter.string(from: record.date)
        let safeDevice = record.device.replacingOccurrences(of: "/", with: "-")
        let fileURL = perfDir.appendingPathComponent("\(dayStr)-\(safeDevice).csv")

        let header = "date,device,model,ttft_ms,decode_tps,peak_mem_mb,thermal\n"
        if !fileManager.fileExists(atPath: fileURL.path) {
            try header.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = record.csvRow.data(using: .utf8) {
            handle.write(data)
        }

        return fileURL
    }

    public static func perfDirectoryURL(fileManager: FileManager = .default) -> URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("perf", isDirectory: true)
    }
}
#endif
