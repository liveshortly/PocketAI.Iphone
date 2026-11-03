import SwiftUI
import PocketKit

@main
struct PocketAIApp: App {
    @State private var model = AppModel.shared

    init() {
        DiagnosticsLog.shared.append("PocketAIApp: application initialized")
        ChatSync.registerBackgroundTask()
        RemoteChatSelfTestRunner.shared.runIfNeeded(model: AppModel.shared)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
        }
    }
}

private final class RemoteChatSelfTestSink: TokenSink, @unchecked Sendable {
    func onDelta(delta: GenerateDelta) {
        fputs(delta.text, stderr)
        fflush(stderr)
    }

    func onDone(stats: GenerateStats) {
        fputs("\n[REMOTE_SELFTEST_DONE] promptTokens=\(stats.promptTokens), completionTokens=\(stats.completionTokens)\n", stderr)
        fflush(stderr)
        exit(0)
    }

    func onError(err: PocketError) {
        fputs("\n[REMOTE_SELFTEST_ERROR] \(err)\n", stderr)
        fflush(stderr)
        exit(1)
    }
}

final class RemoteChatSelfTestRunner: @unchecked Sendable {
    static let shared = RemoteChatSelfTestRunner()
    private let lock = NSLock()
    private var hasRun = false

    func runIfNeeded(model: AppModel) {
        guard ProcessInfo.processInfo.arguments.contains("-PocketRemoteChatSelfTest") else { return }
        lock.lock()
        if hasRun {
            lock.unlock()
            return
        }
        hasRun = true
        lock.unlock()

        fputs("[REMOTE_SELFTEST] Started\n", stderr)
        fflush(stderr)

        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                fputs("[REMOTE_SELFTEST_ERROR] Timed out after 60s\n", stderr)
                fflush(stderr)
                exit(1)
            }

            guard let peer = model.core.peers().first else {
                fputs("[REMOTE_SELFTEST] No paired peer found, skipping\n", stderr)
                fflush(stderr)
                exit(0)
            }
            guard let tokenData = model.hooks.keychainGet(key: peer.tokenRef),
                  let token = String(data: tokenData, encoding: .utf8),
                  let host = peer.addrs.first else {
                fputs("[REMOTE_SELFTEST_ERROR] Failed to get credentials for peer \(peer.name)\n", stderr)
                fflush(stderr)
                exit(1)
            }

            fputs("[REMOTE_SELFTEST] Connecting to peer \(peer.name) at \(host):\(peer.port)\n", stderr)
            fflush(stderr)

            let endpoint = PeerEndpoint(host: host, port: peer.port, fingerprint: peer.certSha256)
            let client = PeerClient(endpoint: endpoint, token: token)
            let engine = RemoteEngine(client: client)

            let remoteModelId = "mac:\(peer.id)/mlx-community/Qwen2.5-0.5B-Instruct-4bit@main"
            let manifest = ModelManifest(
                id: remoteModelId,
                displayName: "Qwen 2.5 0.5B",
                family: "qwen2.5",
                paramsB: 0.5,
                quant: "4bit",
                format: .mlxSafetensors,
                modalities: [.text],
                contextLength: 4096,
                files: [],
                license: LicenseInfo(spdx: "Apache-2.0", commercialOk: true, url: ""),
                hfRepo: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                hfRevision: "main",
                minRamBytes: 0,
                estRuntimeBytes: 0,
                tags: [],
                curated: true,
                reasoning: false
            )

            do {
                let loaded = try engine.load(model: manifest, opts: LoadOptions(contextLength: nil, pinnedEngine: nil))
                fputs("[REMOTE_SELFTEST] Model loaded handle=\(loaded.handle), generating...\n", stderr)
                fflush(stderr)

                let req = GenerateRequest(
                    requestId: UUID().uuidString,
                    messages: [ChatMessage(role: "user", parts: [.text(text: "Hello from iPhone! Say 'Remote model is working' and nothing else.")])],
                    tools: [],
                    params: SamplingParams(
                        temperature: 0.1,
                        topP: 1.0,
                        topK: 40,
                        minP: 0.0,
                        maxTokens: 30,
                        stop: [],
                        seed: nil,
                        repetitionPenalty: 1.0
                    ),
                    reasoning: .off
                )
                let sink = RemoteChatSelfTestSink()
                _ = try engine.generate(handle: loaded.handle, req: req, sink: sink)
            } catch {
                fputs("\n[REMOTE_SELFTEST_ERROR] \(error)\n", stderr)
                fflush(stderr)
                exit(1)
            }
        }
    }
}
