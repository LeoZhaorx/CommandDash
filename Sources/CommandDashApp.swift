import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let fixedSize = NSSize(width: 1320, height: 760)
    private let frameOriginXKey = "CommandDash.windowOriginX"
    private let frameOriginYKey = "CommandDash.windowOriginY"
    private var observers: [NSObjectProtocol] = []
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            for window in NSApp.windows {
                self.configure(window)
            }
            self.observeWindowMoves()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let window = mainWindow {
            saveWindowOrigin(window)
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func configure(_ window: NSWindow) {
        guard window.level == .normal else { return }
        if mainWindow == nil {
            mainWindow = window
        }

        window.styleMask = [.borderless, .fullSizeContentView]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovable = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.setContentSize(fixedSize)
        window.minSize = fixedSize
        window.maxSize = fixedSize
        window.hasShadow = false

        if window === mainWindow,
           let savedX = UserDefaults.standard.object(forKey: frameOriginXKey) as? Double,
           let savedY = UserDefaults.standard.object(forKey: frameOriginYKey) as? Double {
            var frame = window.frame
            frame.origin = NSPoint(x: savedX, y: savedY)
            window.setFrame(frame, display: true)
        }

        // Keep host views fully transparent to avoid hairline artifacts.
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.borderWidth = 0
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.borderWidth = 0
        window.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func observeWindowMoves() {
        guard let trackedWindow = mainWindow else { return }
        let center = NotificationCenter.default

        let didMove = center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: trackedWindow,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            self.saveWindowOrigin(window)
        }

        let willClose = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: trackedWindow,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            self.saveWindowOrigin(window)
        }

        let didBecomeKey = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: trackedWindow,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            self.configure(window)
        }

        observers.append(didMove)
        observers.append(willClose)
        observers.append(didBecomeKey)
    }

    private func saveWindowOrigin(_ window: NSWindow) {
        let origin = window.frame.origin
        UserDefaults.standard.set(origin.x, forKey: frameOriginXKey)
        UserDefaults.standard.set(origin.y, forKey: frameOriginYKey)
    }
}

@main
struct CommandDashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1320, height: 760)

        MenuBarExtra("CommandDash", systemImage: "terminal") {
            MenuBarContentView()
                .environmentObject(appState)
        }
    }
}
