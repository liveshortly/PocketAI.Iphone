import Foundation
import Observation
import PocketKit

@Observable
@MainActor
public final class AppModel {
    public let core: CoreClient

    public init() {
        if ProcessInfo.processInfo.arguments.contains("-PocketPreviewCore") {
            core = PreviewCore()
        } else {
            core = LiveCore()
        }
    }
}
