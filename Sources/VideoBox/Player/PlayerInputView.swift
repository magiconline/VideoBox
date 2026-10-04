import AppKit
import SwiftUI

enum PlayerInputCommand: Equatable {
    case togglePlayback
    case skip(Double)
    case stepFrame(Int)
    case toggleFullscreen
    case exitFullscreen
    case toggleMute
    case adjustVolume(Double)
    case boundary(Bool)
    case jumpClip(Int)
    case toggleLoop
    case setLoopBoundary(Bool)
    case editPoint(Bool)
    case zoom(Double)
    case resetViewing

    static func resolve(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) -> PlayerInputCommand? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        let shifted = modifiers.contains(.shift)
        let command: PlayerInputCommand?
        switch keyCode {
        case 123: command = .skip(shifted ? -1 : -5)
        case 124: command = .skip(shifted ? 1 : 5)
        case 125: command = shifted ? nil : .adjustVolume(-0.05)
        case 126: command = shifted ? nil : .adjustVolume(0.05)
        case 53: command = shifted ? nil : .exitFullscreen
        case 115: command = .boundary(true)
        case 119: command = .boundary(false)
        case 116: command = .jumpClip(-1)
        case 121: command = .jumpClip(1)
        default:
            if shifted, characters == "i" || characters == "I" { return .setLoopBoundary(true) }
            if shifted, characters == "o" || characters == "O" { return .setLoopBoundary(false) }
            if characters == "+" || characters == "=" { return .zoom(1.25) }
            guard !shifted else { return nil }
            switch characters?.lowercased() {
            case " ": command = .togglePlayback
            case ",": command = .stepFrame(-1)
            case ".": command = .stepFrame(1)
            case "f": command = .toggleFullscreen
            case "m": command = .toggleMute
            case "[": command = .jumpClip(-1)
            case "]": command = .jumpClip(1)
            case "l": command = .toggleLoop
            case "i": command = .editPoint(true)
            case "o": command = .editPoint(false)
            case "-": command = .zoom(0.8)
            case "0": command = .resetViewing
            default: command = nil
            }
        }
        if isRepeat {
            switch command {
            case .togglePlayback, .toggleFullscreen, .exitFullscreen, .toggleMute, .toggleLoop, .editPoint, .setLoopBoundary: return nil
            default: break
            }
        }
        return command
    }
}

struct PlayerInputView: NSViewRepresentable {
    @ObservedObject var playerController: PlayerController
    var isEnabled = true

    func makeNSView(context: Context) -> PlayerInputNSView {
        let view = PlayerInputNSView()
        view.playerController = playerController
        view.isInputEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: PlayerInputNSView, context: Context) {
        view.playerController = playerController
        view.isInputEnabled = isEnabled
        view.synchronizeFullscreen()
    }

    static func dismantleNSView(_ view: PlayerInputNSView, coordinator: ()) {
        view.stopObservingWindow()
    }
}

final class PlayerInputNSView: NSView {
    weak var playerController: PlayerController?
    var isInputEnabled = true
    private var pendingClick: DispatchWorkItem?
    private var windowObservers: [NSObjectProtocol] = []
    private var isFullscreenTransitioning = false
    private var fullscreenRequestScheduled = false
    private var hasInitializedWindowState = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("video-preview-input")
        setAccessibilityLabel("预览画面")
        setAccessibilityHelp("单击播放或暂停，双击全屏。聚焦后可使用空格和方向键。")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        pendingClick?.cancel()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        guard let window else { return }
        observe(window: window, name: NSWindow.willEnterFullScreenNotification, entering: true, completed: false)
        observe(window: window, name: NSWindow.willExitFullScreenNotification, entering: false, completed: false)
        observe(window: window, name: NSWindow.didEnterFullScreenNotification, entering: true, completed: true)
        observe(window: window, name: NSWindow.didExitFullScreenNotification, entering: false, completed: true)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.playerController?.setFullscreen(window.styleMask.contains(.fullScreen))
            self.hasInitializedWindowState = true
            if window.isKeyWindow, PlayerInputFocus.canFocus(in: window) {
                window.makeFirstResponder(self)
            }
            self.synchronizeFullscreen()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isInputEnabled, let window, PlayerInputFocus.canInteract(in: window) else { return }
        window.makeFirstResponder(self)
        pendingClick?.cancel()
        if event.modifierFlags.contains(.option) { pendingClick = nil; return }
        if event.clickCount == 2 {
            pendingClick = nil
            playerController?.toggleFullscreen()
            return
        }
        guard event.clickCount == 1 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isInputEnabled, let window = self.window,
                  window.isKeyWindow, PlayerInputFocus.canFocus(in: window) else { return }
            self.playerController?.togglePlayback()
            self.pendingClick = nil
        }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    override func mouseDragged(with event: NSEvent) {
        pendingClick?.cancel()
        pendingClick = nil
        if isInputEnabled, event.modifierFlags.contains(.option) {
            playerController?.panViewing(dx: event.deltaX, dy: event.deltaY)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if isInputEnabled, event.modifierFlags.contains(.option) {
            playerController?.zoomViewing(by: exp(-event.scrollingDeltaY * 0.02))
        } else { super.scrollWheel(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isInputEnabled, let window, PlayerInputFocus.canInteract(in: window) else { return nil }
        window.makeFirstResponder(self)
        let menu = NSMenu()
        for (title, tag) in [("播放 / 暂停", 0), ("上一片段", 1), ("下一片段", 2), ("到开头", 3), ("到结尾", 4), ("设置循环入点（Shift I）", 5), ("设置循环出点（Shift O）", 6), ("区间循环（L）", 7), ("观看放大（+）", 8), ("重置观看（0）", 9), ("全屏（F）", 10)] {
            let item = NSMenuItem(title: title, action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = tag
            if tag == 7 { item.state = playerController?.isLoopEnabled == true ? .on : .off }
            menu.addItem(item)
        }
        return menu
    }
    @objc private func contextAction(_ sender: NSMenuItem) {
        guard let playerController else { return }
        switch sender.tag {
        case 0: playerController.togglePlayback()
        case 1: playerController.jumpToClip(-1)
        case 2: playerController.jumpToClip(1)
        case 3: playerController.seekOutput(to: 0)
        case 4: playerController.seekOutput(to: playerController.outputDuration)
        case 5: playerController.setLoopBoundary(isStart: true)
        case 6: playerController.setLoopBoundary(isStart: false)
        case 7: playerController.isLoopEnabled.toggle()
        case 8: playerController.zoomViewing(by: 1.25)
        case 9: playerController.resetViewing()
        default: playerController.toggleFullscreen()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isInputEnabled, let window, window.isKeyWindow, window.firstResponder === self,
              PlayerInputFocus.canFocus(in: window),
              let command = PlayerInputCommand.resolve(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags,
                isRepeat: event.isARepeat
              ), let playerController else {
            super.keyDown(with: event)
            return
        }
        pendingClick?.cancel()
        pendingClick = nil
        switch command {
        case .togglePlayback: playerController.togglePlayback()
        case let .skip(seconds): playerController.skip(by: seconds)
        case let .stepFrame(direction): playerController.stepFrame(direction)
        case .toggleFullscreen: playerController.toggleFullscreen()
        case .exitFullscreen: playerController.setFullscreen(false)
        case .toggleMute: playerController.toggleMonitoringMute()
        case let .adjustVolume(amount): playerController.adjustMonitoringVolume(by: amount)
        case let .boundary(start): playerController.seekOutput(to: start ? 0 : playerController.outputDuration)
        case let .jumpClip(direction): playerController.jumpToClip(direction)
        case .toggleLoop: playerController.isLoopEnabled.toggle()
        case let .setLoopBoundary(start): playerController.setLoopBoundary(isStart: start)
        case let .editPoint(start): playerController.setEditPoint?(start)
        case let .zoom(factor): playerController.zoomViewing(by: factor)
        case .resetViewing: playerController.resetViewing()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isInputEnabled, let window, PlayerInputFocus.canInteract(in: window) else { return false }
        window.makeFirstResponder(self)
        playerController?.togglePlayback()
        return true
    }

    func synchronizeFullscreen() {
        guard hasInitializedWindowState, !fullscreenRequestScheduled, !isFullscreenTransitioning,
              let window, let playerController,
              window.styleMask.contains(.fullScreen) != playerController.isFullscreen else { return }
        fullscreenRequestScheduled = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            self.fullscreenRequestScheduled = false
            guard let window, self.window === window, !self.isFullscreenTransitioning,
                  let controller = self.playerController,
                  window.styleMask.contains(.fullScreen) != controller.isFullscreen else { return }
            self.isFullscreenTransitioning = true
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      self.isFullscreenTransitioning else { return }
                self.isFullscreenTransitioning = false
                self.playerController?.setFullscreen(window.styleMask.contains(.fullScreen))
            }
        }
    }

    func stopObservingWindow() {
        pendingClick?.cancel()
        pendingClick = nil
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        isFullscreenTransitioning = false
        hasInitializedWindowState = false
    }

    private func observe(window: NSWindow, name: Notification.Name, entering: Bool, completed: Bool) {
        let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFullscreenTransitioning = !completed
                self.playerController?.setFullscreen(entering)
            }
        }
        windowObservers.append(observer)
    }
}

@MainActor
enum PlayerInputFocus {
    static func canInteract(in window: NSWindow) -> Bool {
        window.attachedSheet == nil && NSApp.modalWindow == nil
    }

    static func canFocus(in window: NSWindow) -> Bool {
        guard canInteract(in: window) else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
        if window.firstResponder is NSTextField { return false }
        return true
    }

    static func focusPlayer(
        for controller: PlayerController,
        in window: NSWindow? = nil,
        preservingTextFocus: Bool = true
    ) {
        guard let window = window ?? NSApp.keyWindow,
              window.isKeyWindow, canInteract(in: window),
              !preservingTextFocus || canFocus(in: window),
              let contentView = window.contentView,
              let input = findInput(in: contentView, controller: controller) else { return }
        window.makeFirstResponder(input)
    }

    private static func findInput(in view: NSView, controller: PlayerController) -> PlayerInputNSView? {
        if let input = view as? PlayerInputNSView, input.playerController === controller { return input }
        for subview in view.subviews {
            if let input = findInput(in: subview, controller: controller) { return input }
        }
        return nil
    }
}

/// Attach as a background to the timeline or playback controls. It observes clicks
/// only within this region and never replaces a text editor's first responder.
struct PlayerInputFocusRegion: NSViewRepresentable {
    let playerController: PlayerController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = PlayerInputRegionNSView()
        context.coordinator.start(view: view, controller: playerController)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private var mouseMonitor: Any?

        func start(view: NSView, controller: PlayerController) {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak view, weak controller] event in
                guard let view, let controller, let window = view.window,
                      event.window === window, !view.isHiddenOrHasHiddenAncestor,
                      view.visibleRect.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
                DispatchQueue.main.async { [weak controller, weak window] in
                    guard let controller, let window else { return }
                    PlayerInputFocus.focusPlayer(for: controller, in: window, preservingTextFocus: true)
                }
                return event
            }
        }

        func stop() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
        }

        deinit { stop() }
    }
}

private final class PlayerInputRegionNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
