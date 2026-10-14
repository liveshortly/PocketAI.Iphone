import SwiftUI
import PocketUI

/// Tab shell per 02-design-system.md §6.1. Screens are placeholders until
/// UI-04/UI-07+ land; this proves the shell, PocketUI tokens, and the
/// PocketMark chip render against a real `CoreClient` (Live or Preview).
struct RootTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-PocketComponentGallery") }) {
            ComponentGallery()
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView {
            ChatsPlaceholder()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            Text("Models").tabItem { Label("Models", systemImage: "cpu") }
            Text("Devices").tabItem { Label("Devices", systemImage: "laptopcomputer") }
            Text("Settings").tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(PocketColor.accent)
    }
}

private struct ChatsPlaceholder: View {
    @Environment(AppModel.self) private var model
    @State private var streamed = ""
    @State private var isStreaming = false

    var body: some View {
        NavigationStack {
            VStack(spacing: PocketSpacing.s24) {
                PocketMarkView(state: isStreaming ? .working(tokPerSec: 40) : .idle, size: 64)
                Text(streamed.isEmpty ? "Tap to stream a mock reply" : streamed)
                    .font(.pocket(.body))
                    .foregroundStyle(PocketColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PocketSpacing.gutterIphone)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PocketColor.bgCanvas)
            .navigationTitle("PocketAI")
            .onTapGesture { Task { await stream() } }
        }
    }

    private func stream() async {
        guard !isStreaming else { return }
        isStreaming = true
        streamed = ""
        do {
            for try await chunk in model.core.mockGenerate(seed: 0, tokensPerSec: 40) {
                streamed += chunk
            }
        } catch {
            streamed = "Error: \(error)"
        }
        isStreaming = false
    }
}

#Preview {
    RootTabView().environment(AppModel())
}
