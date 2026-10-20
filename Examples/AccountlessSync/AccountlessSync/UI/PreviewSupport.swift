import GotSync
#if DEBUG
import Foundation
import SwiftUI

@MainActor
enum PreviewSupport {
    static func model(
        seedTaskTitles: [String] = []
    ) -> SyncAppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AccountlessSync-Previews/\(UUID().uuidString)",
                isDirectory: true
            )
        let model = SyncAppModel(baseDirectory: directory)
        for title in seedTaskTitles {
            _ = model.addTask(title: title)
        }
        return model
    }

    static var sampleInvitationURL: URL {
        try! Invitation(
            secret: Data(0..<16),
            groupID: Data(repeating: 0x01, count: 32),
            inviterFingerprint: Data(repeating: 0x02, count: 32)
        ).url(scheme: DemoEndpoints.invitationURLScheme)
    }

    static let samplePhrase =
        "able acid acre aged ahead aid aim air ale all aloe also amber angel anger angle ant"

    static let sampleSafetyCode = "482917"
}
#endif
