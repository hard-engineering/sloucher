import AppKit
import CoreGraphics
import Foundation
import IOKit.ps

final class PowerManager: NSObject {
    var onCaptureDesiredChange: ((Bool, String?) -> Void)?

    var currentSampleInterval: TimeInterval {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return sampleInterval
        }

        return stateQueue.sync {
            sampleInterval
        }
    }

    private let stateQueue = DispatchQueue(label: "app.sloucher.power")
    private let stateQueueKey = DispatchSpecificKey<Void>()
    private var idleTimer: DispatchSourceTimer?
    private var isStarted = false
    private var isSystemSleeping = false
    private var isScreenLocked = false
    private var isDisplaySleeping = false
    private var startedAt = Date()
    private var sampleInterval: TimeInterval = 1.5
    private var lastCaptureDesired: Bool?
    private var lastReason: String?

    override init() {
        super.init()
        sampleInterval = Self.computeSampleInterval()
        stateQueue.setSpecific(key: stateQueueKey, value: ())
    }

    func start() {
        var shouldStart = false

        stateQueue.sync {
            if !isStarted {
                isStarted = true
                startedAt = Date()
                shouldStart = true
            }
        }

        guard shouldStart else { return }

        installObservers()
        startIdleTimer()

        stateQueue.async { [weak self] in
            self?.evaluateCapturePreference()
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        idleTimer?.cancel()
    }

    private func installObservers() {
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(handleScreensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        let distributedNotifications = DistributedNotificationCenter.default()
        distributedNotifications.addObserver(
            self,
            selector: #selector(handleScreenLocked),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributedNotifications.addObserver(
            self,
            selector: #selector(handleScreenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerStateChanged),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.evaluateCapturePreference()
        }
        idleTimer = timer
        timer.resume()
    }

    @objc private func handleWillSleep(_ notification: Notification) {
        stateQueue.async { [weak self] in
            self?.isSystemSleeping = true
            self?.evaluateCapturePreference()
        }
    }

    @objc private func handleDidWake(_ notification: Notification) {
        stateQueue.async { [weak self] in
            self?.isSystemSleeping = false
            self?.isDisplaySleeping = false
            self?.evaluateCapturePreference()
        }
    }

    @objc private func handleScreensDidSleep(_ notification: Notification) {
        stateQueue.async { [weak self] in
            self?.isDisplaySleeping = true
            self?.evaluateCapturePreference()
        }
    }

    @objc private func handleScreensDidWake(_ notification: Notification) {
        stateQueue.async { [weak self] in
            self?.isDisplaySleeping = false
            self?.evaluateCapturePreference()
        }
    }

    @objc private func handleScreenLocked(_ notification: Notification) {
        stateQueue.async { [weak self] in
            self?.isScreenLocked = true
            self?.evaluateCapturePreference()
        }
    }

    @objc private func handleScreenUnlocked(_ notification: Notification) {
        stateQueue.async { [weak self] in
            self?.isScreenLocked = false
            self?.evaluateCapturePreference()
        }
    }

    @objc private func handlePowerStateChanged(_ notification: Notification) {
        stateQueue.async { [weak self] in
            self?.sampleInterval = Self.computeSampleInterval()
        }
    }

    private func evaluateCapturePreference() {
        sampleInterval = Self.computeSampleInterval()

        let idleSeconds = Self.secondsSinceUserInput()
        let shouldCapture: Bool
        let reason: String?

        if isSystemSleeping {
            shouldCapture = false
            reason = "Paused while your Mac is sleeping."
        } else if isDisplaySleeping {
            shouldCapture = false
            reason = "Paused while the display is asleep."
        } else if isScreenLocked {
            shouldCapture = false
            reason = "Paused while the screen is locked."
        } else if Date().timeIntervalSince(startedAt) > 60 && idleSeconds > 60 {
            shouldCapture = false
            reason = "Paused while you're away."
        } else {
            shouldCapture = true
            reason = nil
        }

        guard lastCaptureDesired != shouldCapture || lastReason != reason else {
            return
        }

        lastCaptureDesired = shouldCapture
        lastReason = reason

        DispatchQueue.main.async { [weak self] in
            self?.onCaptureDesiredChange?(shouldCapture, reason)
        }
    }

    private static var isBatteryConstrained: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled || isOnBatteryPower()
    }

    private static func computeSampleInterval() -> TimeInterval {
        isBatteryConstrained ? 3.0 : 1.5
    }

    private static func secondsSinceUserInput() -> TimeInterval {
        let eventTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
            .keyDown,
            .flagsChanged
        ]

        return eventTypes
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .filter { $0.isFinite && $0 >= 0 }
            .min() ?? .greatestFiniteMagnitude
    }

    private static func isOnBatteryPower() -> Bool {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any]
        else {
            return false
        }

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?
                    .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String,
                state == kIOPSBatteryPowerValue
            else {
                continue
            }

            return true
        }

        return false
    }
}
