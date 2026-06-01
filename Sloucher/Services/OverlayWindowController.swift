import AppKit
import Foundation

final class OverlayWindowController {
    private var windows: [NSWindow] = []
    private var screenFrames: [NSRect] = []
    private var screenChangeObserver: NSObjectProtocol?
    private var isShowing = false

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        windows.forEach { $0.close() }
    }

    func show() {
        performOnMain { [weak self] in
            guard let self else { return }
            let latestScreenFrames = NSScreen.screens.map(\.frame)
            isShowing = true
            startObservingScreenChanges()

            if windows.isEmpty || latestScreenFrames != screenFrames {
                rebuildWindows(screenFrames: latestScreenFrames)
            } else {
                windows.forEach { $0.orderFrontRegardless() }
            }
        }
    }

    func hide() {
        performOnMain { [weak self] in
            guard let self else { return }
            isShowing = false
            windows.forEach { $0.orderOut(nil) }
        }
    }

    private func startObservingScreenChanges() {
        guard screenChangeObserver == nil else { return }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, isShowing else { return }
            rebuildWindows(screenFrames: NSScreen.screens.map(\.frame))
        }
    }

    private func rebuildWindows(screenFrames: [NSRect]) {
        windows.forEach { $0.close() }
        self.screenFrames = screenFrames
        windows = NSScreen.screens.map(makeWindow(for:))
        windows.forEach { $0.orderFrontRegardless() }
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = PassthroughOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.backgroundColor = .clear
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        window.contentView = EdgeGlowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.isMovable = false
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.level = .screenSaver

        return window
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

private final class PassthroughOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class EdgeGlowView: NSView {
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        NSColor.clear.setFill()
        dirtyRect.fill()

        let red = NSColor.systemRed
        let strokes: [(width: CGFloat, alpha: CGFloat)] = [
            (10, 0.80),
            (22, 0.34),
            (38, 0.18),
            (58, 0.10)
        ]

        for stroke in strokes {
            let inset = stroke.width / 2
            let rect = bounds.insetBy(dx: inset, dy: inset)
            guard rect.width > 0, rect.height > 0 else { continue }

            let path = NSBezierPath(rect: rect)
            path.lineWidth = stroke.width
            red.withAlphaComponent(stroke.alpha).setStroke()
            path.stroke()
        }
    }
}
