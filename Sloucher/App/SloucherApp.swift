import AppKit
import Combine
import SwiftUI

@main
struct SloucherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var statusBarWindowController: StatusBarWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let windowController = StatusBarWindowController(appState: appState)
        statusBarWindowController = windowController
        appState.refreshPermissionStatuses()
        DispatchQueue.main.async {
            windowController.presentInitialBlockingPermissionWindowIfNeeded()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState.refreshPermissionStatuses()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

final class StatusBarWindowController: NSObject, NSWindowDelegate {
    private let mainWindowFrameSize = NSSize(width: 700, height: 660)
    private let mainWindowMinimumSize = NSSize(width: 700, height: 540)
    private let appState: AppState
    private let statusItem: NSStatusItem
    private var window: NSWindow?
    private lazy var statusContextMenu: NSMenu = makeStatusMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var didHandleInitialCameraStatus = false

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configureAppStateCallbacks()
        observeInitialCameraStatus()
    }

    private func configureStatusItem() {
        statusItem.length = NSStatusItem.squareLength
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = statusBarImage()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.toolTip = "Open Sloucher"
        button.setAccessibilityLabel("Sloucher")
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown ||
            (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true) {
            showStatusMenu(from: sender)
            return
        }

        openSloucher()
    }

    @objc private func openSloucher() {
        appState.refreshPermissionStatuses()
        presentMainWindow(activate: true)
    }

    @objc private func quitSloucher() {
        appState.quit()
    }

    private func observeInitialCameraStatus() {
        appState.$hasCheckedCameraAuthorization
            .combineLatest(appState.$cameraAuthorization)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasChecked, authorization in
                guard let self, hasChecked, !self.didHandleInitialCameraStatus else { return }
                self.didHandleInitialCameraStatus = true

                if authorization != .authorized {
                    self.presentMainWindow(activate: true)
                }
            }
            .store(in: &cancellables)
    }

    private func configureAppStateCallbacks() {
        appState.onInitialBlockingPermissionNeeded = { [weak self] in
            self?.presentInitialBlockingPermissionWindow()
        }
        appState.onCameraPermissionRequestFinished = { [weak self] in
            self?.presentMainWindow(activate: true)
        }
        appState.onCameraPermissionSatisfied = { [weak self] in
            self?.presentMainWindow(activate: true)
        }
    }

    private func presentInitialBlockingPermissionWindow() {
        guard !didHandleInitialCameraStatus else { return }
        didHandleInitialCameraStatus = true
        presentMainWindow(activate: true)
    }

    func presentInitialBlockingPermissionWindowIfNeeded() {
        guard
            appState.hasCheckedCameraAuthorization,
            appState.cameraAuthorization != .authorized,
            window == nil
        else {
            return
        }

        didHandleInitialCameraStatus = true
        presentMainWindow(activate: true)
    }

    private func presentMainWindow(activate: Bool) {
        let createdWindow = window == nil
        let mainWindow = window ?? makeMainWindow()
        if createdWindow {
            window = mainWindow
            center(mainWindow)
        }

        if mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        }
        mainWindow.makeKeyAndOrderFront(nil)

        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func makeMainWindow() -> NSWindow {
        let contentView = MainWindowRootView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: contentView)
        let mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: mainWindowFrameSize.width, height: mainWindowFrameSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.title = "Sloucher"
        mainWindow.contentViewController = hostingController
        mainWindow.delegate = self
        mainWindow.canHide = false
        mainWindow.hidesOnDeactivate = false
        mainWindow.isReleasedWhenClosed = false
        mainWindow.contentMinSize = mainWindowMinimumSize
        mainWindow.collectionBehavior = [.moveToActiveSpace]
        return mainWindow
    }

    private func center(_ window: NSWindow) {
        guard let screen = NSScreen.main else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let frameSize = NSSize(
            width: max(window.frame.width, mainWindowFrameSize.width),
            height: min(max(window.frame.height, mainWindowFrameSize.height), max(mainWindowMinimumSize.height, visibleFrame.height - 24))
        )
        let centeredX = visibleFrame.midX - frameSize.width / 2
        let centeredY = visibleFrame.midY - frameSize.height / 2
        let x = clamped(
            centeredX,
            lower: visibleFrame.minX + 12,
            upper: max(visibleFrame.minX + 12, visibleFrame.maxX - frameSize.width - 12)
        )
        let y = clamped(
            centeredY,
            lower: visibleFrame.minY + 12,
            upper: max(visibleFrame.minY + 12, visibleFrame.maxY - frameSize.height - 12)
        )
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: frameSize), display: false)
    }

    private func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    private func statusBarImage() -> NSImage? {
        // Dedicated template glyph (mark-only slouching figure) from the asset
        // catalog; adapts to light/dark menu bars and stays crisp at 18pt,
        // unlike the previous scaled-down .icns app icon.
        guard let image = NSImage(named: "MenuBarIcon") else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Sloucher", action: #selector(openSloucher), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitSloucher), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        statusItem.menu = statusContextMenu
        button.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
