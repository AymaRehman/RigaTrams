import SwiftUI

/// Entry point. The app has no normal windows: AppDelegate creates the
/// desktop board and the menu bar icon.
@main
struct RigaTramsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
