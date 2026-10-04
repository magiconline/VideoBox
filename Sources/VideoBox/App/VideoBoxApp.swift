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
    @StateObject private var environment = AppEnvironment(persistsQueue: true)

    var body: some Scene {
        Window("VideoBox", id: "main") {
            HomeView()
                .environmentObject(environment)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1_220, height: 800)
        .commands { VideoBoxProjectCommands() }
    }
}

struct VideoBoxProjectCommands: Commands {
    @FocusedValue(\.projectActions) var actions: ProjectActions?
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { actions?.session.undo() } }.keyboardShortcut("z").disabled(actions?.session.canUndo != true && !(NSApp.keyWindow?.firstResponder is NSTextView))
            Button("重做") { if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { actions?.session.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(actions?.session.canRedo != true && !(NSApp.keyWindow?.firstResponder is NSTextView))
        }
        CommandGroup(after: .newItem) {
            Button("打开工程…") { actions?.open() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("保存工程…") { actions?.save() }.keyboardShortcut("s").disabled(actions?.session.sourceURL == nil)
            Button("工程另存为…") { actions?.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(actions?.session.sourceURL == nil)
            Button("添加时间线素材…") { actions?.appendMedia() }.disabled(actions?.session.sourceURL == nil)
        }
    }
}
