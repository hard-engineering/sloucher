import AppKit
import Foundation
import UserNotifications

final class Nudger: NSObject, UNUserNotificationCenterDelegate {
    private let notificationCenter: UNUserNotificationCenter
    private let overlayWindowController: OverlayWindowController
    private let reminderInterval: TimeInterval

    private var lastStatus: PostureStatus?
    private var lastNotificationDate: Date?
    private var notificationSequence = 0
    private var hasPlayedSoundForCurrentSlouch = false
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
        overlayEnabled: Bool
    ) {
        performOnMain { [weak self] in
            self?.applyUpdate(
                status: status,
                notificationsEnabled: notificationsEnabled,
                soundEnabled: soundEnabled,
                overlayEnabled: overlayEnabled
            )
        }
    }

    func clear() {
        performOnMain { [weak self] in
            guard let self else { return }
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
        completionHandler([.banner, .list])
    }

    private func applyUpdate(
        status: PostureStatus,
        notificationsEnabled: Bool,
        soundEnabled: Bool,
        overlayEnabled: Bool
    ) {
        guard status == .slouching else {
            lastStatus = status
            lastNotificationDate = nil
            hasPlayedSoundForCurrentSlouch = false
            overlayWindowController.hide()
            return
        }

        let now = Date()
        let isNewSlouch = lastStatus != .slouching

        if overlayEnabled {
            overlayWindowController.show()
        } else {
            overlayWindowController.hide()
        }

        if isNewSlouch {
            if notificationsEnabled {
                sendSlouchNotification()
                lastNotificationDate = now
            } else {
                lastNotificationDate = nil
            }

            if soundEnabled {
                playSlouchSound()
            }
            hasPlayedSoundForCurrentSlouch = true
        } else if shouldRenotify(now: now, notificationsEnabled: notificationsEnabled) {
            sendSlouchNotification()
            lastNotificationDate = now
        }

        lastStatus = status
    }

    private func shouldRenotify(now: Date, notificationsEnabled: Bool) -> Bool {
        guard notificationsEnabled else { return false }
        guard let lastNotificationDate else { return true }
        return now.timeIntervalSince(lastNotificationDate) >= reminderInterval
    }

    private func sendSlouchNotification() {
        notificationSequence += 1

        let content = UNMutableNotificationContent()
        content.title = "Slouching"
        content.body = "Sit upright to clear the posture alert."
        content.sound = .default
        content.threadIdentifier = "sloucher.slouch"

        let request = UNNotificationRequest(
            identifier: "sloucher.slouch.\(notificationSequence)",
            content: content,
            trigger: nil
        )

        notificationCenter.add(request)
    }

    private func playSlouchSound() {
        guard !hasPlayedSoundForCurrentSlouch else { return }

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
