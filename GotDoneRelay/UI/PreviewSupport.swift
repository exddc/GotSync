#if DEBUG
import Foundation
import SwiftUI

@MainActor
enum PreviewSupport {
    static func model(
        seedTaskTitles: [String] = [],
        seedPairedGroupMemberCount: Int? = nil
    ) -> SyncAppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GotDoneRelay-Previews/\(UUID().uuidString)",
                isDirectory: true
            )
        let model = SyncAppModel(baseDirectory: directory)
        for title in seedTaskTitles {
            _ = model.addTask(title: title)
        }
        if let memberCount = seedPairedGroupMemberCount {
            model.seedGroupUIForDebug(memberCount: memberCount)
        }
        return model
    }

    static var sampleInvitationURL: URL {
        URL(string: "gotdone://pair/v2/preview-invitation")!
    }

    static let samplePhrase =
        "able acid acre aged ahead aid aim air ale all aloe also amber angel anger angle ant"

    static let sampleSafetyCode = "482917"
}
#endif
