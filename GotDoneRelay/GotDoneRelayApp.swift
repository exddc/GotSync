import SwiftUI

@main
struct GotDoneRelayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

#if DEBUG
enum GotDoneDebugLaunch {
    static var shouldCreateInvite: Bool {
        ProcessInfo.processInfo.arguments.contains("-GotDoneDebugCreate")
    }

    static var shouldInviteToGroup: Bool {
        ProcessInfo.processInfo.arguments.contains("-GotDoneDebugInvite")
    }

    static var shouldApproveSafety: Bool {
        ProcessInfo.processInfo.arguments.contains("-GotDoneDebugApprove")
    }

    static var shouldAutoApproveSafety: Bool {
        ProcessInfo.processInfo.arguments.contains("-GotDoneDebugAutoApprove")
    }

    static var shouldErase: Bool {
        ProcessInfo.processInfo.arguments.contains("-GotDoneDebugErase")
    }

    static var joinURL: URL? {
        guard
            let index = ProcessInfo.processInfo.arguments.firstIndex(
                of: "-GotDoneDebugJoinURL"
            ),
            ProcessInfo.processInfo.arguments.indices.contains(index + 1),
            let url = URL(
                string: ProcessInfo.processInfo.arguments[index + 1]
            )
        else {
            return nil
        }
        return url
    }

    /// Seeds a 3-member linked group for Manage Sync UI screenshots.
    static var shouldSeedGroupUI: Bool {
        ProcessInfo.processInfo.arguments.contains("-GotDoneDebugSeedGroupUI")
    }

    /// After seeding/linking, open Manage Sync sheet (screenshot helper).
    static var shouldOpenManageSync: Bool {
        ProcessInfo.processInfo.arguments.contains("-GotDoneDebugOpenManageSync")
    }

    /// After seeding/linking, open group invite UI (screenshot helper).
    static var shouldOpenGroupInvite: Bool {
        ProcessInfo.processInfo.arguments.contains("-GotDoneDebugOpenGroupInvite")
    }
}
#endif
