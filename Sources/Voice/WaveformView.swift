import SwiftUI
import PocketUI

/// Waveform visualization displaying live audio level bars.
public struct WaveformView: View {
    let levels: [Float]

    public init(levels: [Float]) {
        self.levels = levels
    }

    public var body: some View {
        HStack(spacing: PocketSpacing.s4) {
            ForEach(0..<levels.count, id: \.self) { index in
                Capsule()
                    .fill(PocketColor.accent)
                    .frame(width: 3, height: max(6, CGFloat(levels[index]) * 24))
            }
        }
        .frame(height: 28)
        .animation(.easeInOut(duration: 0.08), value: levels)
    }
}

#Preview {
    WaveformView(levels: [0.1, 0.3, 0.6, 0.9, 0.7, 0.4, 0.2, 0.5, 0.8, 0.6, 0.3, 0.1])
        .padding()
        .background(PocketColor.bgCanvas)
}
