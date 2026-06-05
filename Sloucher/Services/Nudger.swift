import AppKit
import Foundation
import OSLog
import UserNotifications

final class Nudger: NSObject, UNUserNotificationCenterDelegate {
    private let notificationLog = Logger(subsystem: "app.sloucher.Sloucher", category: "notifications")
    private let notificationCenter: UNUserNotificationCenter
    private let overlayWindowController: OverlayWindowController
    private let reminderInterval: TimeInterval

    private var lastStatus: PostureStatus?
    private var lastNotificationDate: Date?
    private var notificationSequence = 0
    private var hasPlayedSoundForCurrentSlouch = false
    private var testPreviewUntil: Date?
    private var testPreviewClearWorkItem: DispatchWorkItem?
    private lazy var slouchSound: NSSound? = {
        let sound = NSSound(named: NSSound.Name("Glass")) ??
            NSSound(named: NSSound.Name("Ping")) ??
            NSSound(named: NSSound.Name("Tink"))
        sound?.volume = 0.75
        return sound
    }()

    init(
        notificationCenter: UNUserNotificationCenter = .current(),
        overlayWindowController: OverlayWindowController = OverlayWindowController(),
        reminderInterval: TimeInterval = 180
    ) {
        self.notificationCenter = notificationCenter
        self.overlayWindowController = overlayWindowController
        self.reminderInterval = reminderInterval
        super.init()
        notificationCenter.delegate = self
    }

    func update(
        status: PostureStatus,
        notificationsEnabled: Bool,
        soundEnabled: Bool,
        overlayEnabled: Bool,
        notificationDelay: TimeInterval = 0
    ) {
        performOnMain { [weak self] in
            self?.applyUpdate(
                status: status,
                notificationsEnabled: notificationsEnabled,
                soundEnabled: soundEnabled,
                overlayEnabled: overlayEnabled,
                notificationDelay: notificationDelay
            )
        }
    }

    func testNudge(
        notificationsEnabled: Bool,
        soundEnabled: Bool,
        overlayEnabled: Bool,
        notificationDelay: TimeInterval,
        previewDuration: TimeInterval
    ) {
        performOnMain { [weak self] in
            self?.applyTestNudge(
                notificationsEnabled: notificationsEnabled,
                soundEnabled: soundEnabled,
                overlayEnabled: overlayEnabled,
                notificationDelay: notificationDelay,
                previewDuration: previewDuration
            )
        }
    }

    func clear() {
        performOnMain { [weak self] in
            guard let self else { return }
            cancelTestPreview()
            lastStatus = nil
            lastNotificationDate = nil
            hasPlayedSoundForCurrentSlouch = false
            slouchSound?.stop()
            overlayWindowController.hide()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        notificationLog.info(
            "slouch notification willPresent identifier=\(notification.request.identifier, privacy: .public) presentation=banner,list,sound"
        )
        completionHandler([.banner, .list, .sound])
    }

    private func applyUpdate(
        status: PostureStatus,
        notificationsEnabled: Bool,
        soundEnabled: Bool,
        overlayEnabled: Bool,
        notificationDelay: TimeInterval
    ) {
        guard status == .slouching else {
            lastStatus = status
            lastNotificationDate = nil
            hasPlayedSoundForCurrentSlouch = false
            // A manual Test nudge should remain visible even while normal tracking keeps reporting good posture.
            guard !isTestPreviewActive else { return }
            overlayWindowController.hide()
            return
        }

        cancelTestPreview()
        let now = Date()
        let isNewSlouch = lastStatus != .slouching

        if overlayEnabled {
            overlayWindowController.show()
        } else {
            overlayWindowController.hide()
        }

        if isNewSlouch {
            if notificationsEnabled {
                sendSlouchNotification(delay: notificationDelay)
                lastNotificationDate = now
            } else {
                lastNotificationDate = nil
            }

            if soundEnabled {
                playSlouchSound()
            }
            hasPlayedSoundForCurrentSlouch = true
        } else if shouldRenotify(now: now, notificationsEnabled: notificationsEnabled) {
            sendSlouchNotification(delay: 0)
            lastNotificationDate = now
        }

        lastStatus = status
    }

    private func applyTestNudge(
        notificationsEnabled: Bool,
        soundEnabled: Bool,
        overlayEnabled: Bool,
        notificationDelay: TimeInterval,
        previewDuration: TimeInterval
    ) {
        let duration = max(0, previewDuration)
        let previewUntil = Date().addingTimeInterval(duration)
        testPreviewUntil = previewUntil
        testPreviewClearWorkItem?.cancel()

        notificationLog.info(
            "test nudge preview started duration=\(duration, privacy: .public) notificationsEnabled=\(notificationsEnabled, privacy: .public) overlayEnabled=\(overlayEnabled, privacy: .public) soundEnabled=\(soundEnabled, privacy: .public)"
        )

        if overlayEnabled {
            overlayWindowController.show()
        } else if lastStatus != .slouching {
            overlayWindowController.hide()
        }

        if notificationsEnabled {
            sendSlouchNotification(delay: notificationDelay)
        }

        if soundEnabled {
            playSlouchSound(force: true)
        }

        let work = DispatchWorkItem { [weak self] in
            self?.clearTestPreview(expiringAt: previewUntil)
        }
        testPreviewClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private var isTestPreviewActive: Bool {
        guard let testPreviewUntil else { return false }
        return testPreviewUntil > Date()
    }

    private func cancelTestPreview() {
        testPreviewClearWorkItem?.cancel()
        testPreviewClearWorkItem = nil
        testPreviewUntil = nil
    }

    private func clearTestPreview(expiringAt previewUntil: Date) {
        guard testPreviewUntil == previewUntil else { return }

        testPreviewClearWorkItem = nil
        testPreviewUntil = nil
        notificationLog.info("test nudge preview ended")

        guard lastStatus != .slouching else { return }
        overlayWindowController.hide()
    }

    private func shouldRenotify(now: Date, notificationsEnabled: Bool) -> Bool {
        guard notificationsEnabled else { return false }
        guard let lastNotificationDate else { return true }
        return now.timeIntervalSince(lastNotificationDate) >= reminderInterval
    }

    private func sendSlouchNotification(delay: TimeInterval) {
        notificationSequence += 1

        let content = UNMutableNotificationContent()
        content.title = "Slouching"
        content.body = "Sit upright to clear the posture alert."
        content.sound = .default
        content.interruptionLevel = .active
        content.threadIdentifier = "sloucher.slouch"

        let request = UNNotificationRequest(
            identifier: "sloucher.slouch.\(notificationSequence)",
            content: content,
            trigger: notificationTrigger(delay: delay)
        )

        notificationCenter.getNotificationSettings { [notificationCenter, notificationLog] settings in
            notificationLog.info(
                "slouch notification add started identifier=\(request.identifier, privacy: .public) authorization=\(Self.authorizationStatusName(settings.authorizationStatus), privacy: .public) alertSetting=\(Self.notificationSettingName(settings.alertSetting), privacy: .public) alertStyle=\(Self.alertStyleName(settings.alertStyle), privacy: .public) soundSetting=\(Self.notificationSettingName(settings.soundSetting), privacy: .public) notificationCenterSetting=\(Self.notificationSettingName(settings.notificationCenterSetting), privacy: .public) interruptionLevel=\(Self.interruptionLevelName(request.content.interruptionLevel), privacy: .public) trigger=\(Self.triggerName(request.trigger), privacy: .public)"
            )
            notificationCenter.add(request) { error in
                if let error {
                    notificationLog.error(
                        "slouch notification add failed identifier=\(request.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                } else {
                    notificationLog.info(
                        "slouch notification add succeeded identifier=\(request.identifier, privacy: .public)"
                    )
                }
            }
        }
    }

    private func notificationTrigger(delay: TimeInterval) -> UNNotificationTrigger? {
        guard delay > 0 else { return nil }
        return UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
    }

    private static func authorizationStatusName(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            "notDetermined"
        case .denied:
            "denied"
        case .authorized:
            "authorized"
        case .provisional:
            "provisional"
        case .ephemeral:
            "ephemeral"
        @unknown default:
            "unknown"
        }
    }

    private static func notificationSettingName(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported:
            "notSupported"
        case .disabled:
            "disabled"
        case .enabled:
            "enabled"
        @unknown default:
            "unknown"
        }
    }

    private static func alertStyleName(_ style: UNAlertStyle) -> String {
        switch style {
        case .none:
            "none"
        case .banner:
            "banner"
        case .alert:
            "alert"
        @unknown default:
            "unknown"
        }
    }

    private static func interruptionLevelName(_ level: UNNotificationInterruptionLevel) -> String {
        switch level {
        case .passive:
            "passive"
        case .active:
            "active"
        case .timeSensitive:
            "timeSensitive"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }
    }

    private static func triggerName(_ trigger: UNNotificationTrigger?) -> String {
        guard let trigger else { return "immediate" }

        if let timeIntervalTrigger = trigger as? UNTimeIntervalNotificationTrigger {
            return "timeInterval(\(timeIntervalTrigger.timeInterval)s)"
        }

        return String(describing: type(of: trigger))
    }

    private func playSlouchSound(force: Bool = false) {
        guard force || !hasPlayedSoundForCurrentSlouch else { return }

        guard let slouchSound else {
            NSSound.beep()
            return
        }

        slouchSound.stop()
        slouchSound.currentTime = 0
        if !slouchSound.play() {
            NSSound.beep()
        }
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
