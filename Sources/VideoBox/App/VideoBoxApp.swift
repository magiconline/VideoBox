import AppKit
import SwiftUI

final class VideoBoxAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
@MainActor
struct VideoBoxApp: App {
    @NSApplicationDelegateAdaptor(VideoBoxAppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup("VideoBox") {
            HomeView()
                .environmentObject(environment)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1_220, height: 800)
    }
}
