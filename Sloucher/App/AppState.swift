import AppKit
import AVFoundation
import Combine
import CoreImage
import Foundation
import ImageIO
import UserNotifications
import UniformTypeIdentifiers

enum NotificationPermissionStatus: Equatable {
    case notDetermined
    case requesting
    case provisional
    case authorized
    case denied

    var canScheduleNotifications: Bool {
        switch self {
        case .provisional, .authorized:
            true
        case .notDetermined, .requesting, .denied:
            false
        }
    }
}

final class AppState: ObservableObject {
    @Published var settings = SettingsStore()
    @Published private(set) var status: PostureStatus = .uncalibrated {
        didSet {
            guard status != oldValue else { return }
            statusChangedAt = Date()
        }
    }
    @Published private(set) var statusChangedAt = Date()
    @Published private(set) var latestMetrics: PostureMetrics?
    @Published private(set) var latestPose: PoseFrame?
    @Published private(set) var latestFrameImage: CGImage?
    @Published private(set) var lastFrameDiagnostics: PostureFrameDiagnostics = .empty
    @Published private(set) var metricHistory: [MetricHistorySample] = []
    @Published private(set) var postureScore: Int?
    @Published private(set) var inspectorVisible = false
    @Published private(set) var isNudgePreviewActive = false
    @Published private(set) var calibrationBodySamples = 0
    @Published private(set) var calibrationRequiredSamples = 6
    @Published private(set) var calibrationFrameCount = 0
    @Published private(set) var calibrationLastIssue: String?
    @Published private(set) var detailText: String?
    @Published private(set) var cameraAuthorization: CameraAuthorization = .notDetermined
    @Published private(set) var hasCheckedCameraAuthorization = false
    @Published private(set) var notificationPermissionStatus: NotificationPermissionStatus = .notDetermined
    @Published private(set) var isPermissionSetupVisible = false
    var onInitialBlockingPermissionNeeded: (() -> Void)?
    var onCameraPermissionRequestFinished: (() -> Void)?
    var onCameraPermissionSatisfied: (() -> Void)?
    @Published var launchAtLoginEnabled: Bool = false {
        didSet {
            guard launchAtLoginEnabled != loginItemManager.isEnabled else { return }
            do {
                try loginItemManager.setEnabled(launchAtLoginEnabled)
            } catch {
                detailText = "Launch at login failed: \(error.localizedDescription)"
                launchAtLoginEnabled = loginItemManager.isEnabled
            }
        }
    }

    private let cameraController = CameraController()
    private let postureAnalyzer = PostureAnalyzer()
    private let calibrator = Calibrator()
    private let nudger = Nudger()
    private let powerManager = PowerManager()
    private let loginItemManager = LoginItemManager()
    private let runtimeDefaults = UserDefaults.standard
    private let analysisQueue = DispatchQueue(label: "app.sloucher.analysis", qos: .utility)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var cancellables: Set<AnyCancellable> = []
    private var isManuallyPaused = false
    private var isPowerPaused = false
    private var hasReliableTrackingSample = false
    private var powerPauseReason: String?
    private var snoozeUntil: Date?
    private var smoothedScore: Double?
    private var lastScoreUpdateAt: Date?
    private var recentBodyCalibrationMetrics: [PostureMetrics] = []
    private var calibrationFrames = 0
    private var calibrationBodySuccesses = 0
    private var calibrationBodyObservationTotal = 0
    private var calibrationValidBodyCandidateTotal = 0
    private var calibrationFaceDetectedFrames = 0
    private var calibrationDebugOrientationSweeps: [PostureOrientationSweepDiagnostics] = []
    private var trackingDebugFrames: [PostureTrackingFrameDiagnostics] = []
    private var trackingDebugFrameNumber = 0
    private var trackingDebugOrientationSweeps: [PostureOrientationSweepDiagnostics] = []
    private var lastValidForensicFrame: ForensicFrameSnapshot?
    private var pendingForensicCollapse: ForensicFrameSnapshot?
    private var nextForensicCaptureAllowedAt = Date.distantPast
    private var permissionPollingTimer: Timer?
    private var cameraFrameWaitID: UUID?

    private struct RawPlaneDump {
        let name: String
        let data: Data
    }

    private struct ForensicFrameSnapshot {
        let trackingFrame: PostureTrackingFrameDiagnostics
        let pixelBuffer: PosturePixelBufferDiagnostics
        let image: CGImage?
        let rawPlanes: [RawPlaneDump]
        let bodyObservations: [PostureBodyObservationDiagnostics]
        let orientationSweepResults: [PostureOrientationDiagnostics]
    }

    var hasBaseline: Bool {
        settings.baseline?.hasBodyBaseline == true
    }

    var canCalibrate: Bool {
        status != .cameraPermissionNeeded &&
            status != .cameraDenied &&
            status != .cameraStarting &&
            status != .cameraNoFrames &&
            status != .cameraUnavailable &&
            status != .calibrating
    }

    var isPaused: Bool {
        isManuallyPaused
    }

    var notificationNudgesEnabled: Bool {
        settings.notificationsEnabled && notificationPermissionStatus.canScheduleNotifications
    }

    var shouldShowPermissionSetup: Bool {
        cameraAuthorization != .authorized
    }

    var displayBaselineDistance: Double? {
        guard let baseline = settings.baseline, baseline.hasBodyBaseline else { return nil }
        return baseline.neckDistance
    }

    var liveMetrics: PostureMetrics? {
        status == .cannotSee ? nil : latestMetrics
    }

    var slouchThreshold: Double? {
        displayBaselineDistance.map { $0 * (1 - settings.decisionConfig.dropThreshold) }
    }

    var displayClosenessThreshold: Double {
        settings.decisionConfig.closenessThreshold
    }

    var isLeanSignalCurrentlyTriggering: Bool {
        guard status != .cannotSee, let metrics = liveMetrics else { return false }

        guard let baseline = settings.baseline, metrics.source == .body else { return false }

        return (metrics.closeness > displayClosenessThreshold &&
            metrics.neckDistance < baseline.neckDistance * 0.98) ||
            (metrics.closeness > displayClosenessThreshold + 0.12 &&
                metrics.neckDistance < baseline.neckDistance * 1.02)
    }

    var baselineHeadY: Double? {
        guard let baseline = settings.baseline, baseline.hasBodyBaseline else { return nil }

        guard
            let shoulderMidY = latestPose?.shoulderMidY,
            let shoulderWidth = latestPose?.shoulderWidth
        else {
            return nil
        }

        return shoulderMidY + baseline.neckDistance * shoulderWidth
    }

    var currentDropPercent: Double? {
        guard
            let metrics = latestMetrics,
            let baseline = displayBaselineDistance,
            status != .cannotSee,
            baseline > 0
        else {
            return nil
        }

        return (baseline - metrics.neckDistance) / baseline * 100
    }

    var samplingRateText: String {
        if calibrator.isCollecting || inspectorVisible {
            return "15 Hz"
        }

        let rate = 1 / max(0.1, powerManager.currentSampleInterval)
        return "\(rate.formatted(.number.precision(.fractionLength(1)))) Hz"
    }

    var statusBadgeText: String {
        switch status {
        case .good:
            "Good posture"
        case .slouching:
            "Slouching"
        case .calibrating:
            "Calibrating..."
        case .cannotSee:
            lastFrameDiagnostics.faceDetected ? "Need shoulders" : "Need better view"
        case .uncalibrated:
            "Needs calibration"
        case .cameraPermissionNeeded:
            "Camera needed"
        case .cameraStarting:
            "Camera starting"
        case .cameraNoFrames:
            "Camera waiting"
        default:
            status.displayName
        }
    }

    var inspectorGuidanceText: String? {
        if status == .calibrating {
            if calibrationBodySamples == 0 {
                let issue = calibrationLastIssue.map { " \($0)" } ?? ""
                return "Finding a stable shoulder line - checked \(calibrationFrameCount) frames.\(issue)"
            }

            let issue = calibrationLastIssue.map { " \($0)" } ?? ""
            return "Hold still - collected \(calibrationBodySamples)/\(calibrationRequiredSamples) shoulder samples across \(calibrationFrameCount) frames.\(issue)"
        }

        if !hasBaseline {
            return detailText ?? "Click Calibrate once your head and both shoulders are visible."
        }

        if status == .cameraPermissionNeeded || status == .cameraStarting || status == .cameraNoFrames {
            return detailText
        }

        if status == .cannotSee {
            return Self.trackingGuidance(
                faceDetected: lastFrameDiagnostics.faceDetected,
                detail: lastFrameDiagnostics.bodyFailureReason ?? detailText
            )
        }

        return nil
    }

    init() {
        if settings.baseline?.hasBodyBaseline != true {
            settings.clearBaseline()
        }
        postureAnalyzer.baseline = settings.baseline
        launchAtLoginEnabled = loginItemManager.isEnabled
        // Seeded calibration is no longer used; clear old counters at launch
        // so diagnostics do not imply a stale shortcut path is active.
        runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationSeedCandidates)
        runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationSeedAccepted)
        resetTrackingDebugDiagnostics()
        configureServices()
        configureSettingsObservation()
    }

    func startCalibration() {
        let requiredSamples = 6
        if settings.baseline?.hasBodyBaseline != true {
            settings.clearBaseline()
        }
        detailText = "Sit upright for 2 seconds."
        status = .calibrating
        calibrationBodySamples = 0
        calibrationRequiredSamples = requiredSamples
        calibrationFrameCount = 0
        calibrationLastIssue = nil
        postureScore = nil
        smoothedScore = nil
        lastScoreUpdateAt = nil
        metricHistory = []
        runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationBodySamples)
        runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationFrames)
        runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationBodySuccesses)
        runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationRejectedSamples)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.calibrationLastFailure)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.calibrationLastRejectReason)
        publishRuntimeDiagnostics(status: status, detail: detailText, metrics: latestMetrics)
        nudger.clear()

        analysisQueue.sync {
            // Calibration samples must start after the user clicks Calibrate.
            // Do not seed from recent tracking frames; the user explicitly
            // expects calibration to measure the current deliberate posture.
            calibrator.start(duration: 2, minimumSamples: requiredSamples)
            calibrationFrames = 0
            calibrationBodySuccesses = 0
            calibrationBodyObservationTotal = 0
            calibrationValidBodyCandidateTotal = 0
            calibrationFaceDetectedFrames = 0
            calibrationDebugOrientationSweeps = []
            postureAnalyzer.resetCalibrationDebugDiagnostics()
            resetTrackingDebugDiagnostics()
            runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationSeedCandidates)
            runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationSeedAccepted)
            runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationRejectedSamples)
            runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationBodyObservationTotal)
            runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationValidBodyCandidateTotal)
            runtimeDefaults.set(0, forKey: RuntimeKeys.calibrationFaceDetectedFrames)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.calibrationDebugOrientationSweeps)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.calibrationDebugBestOrientation)
        }

        calibrationBodySamples = 0

        cameraController.forceNextFrame()
        startCameraIfAllowed()
    }

    func togglePause() {
        if isManuallyPaused {
            isManuallyPaused = false
            guard cameraAuthorization == .authorized else {
                refreshPermissionStatuses()
                return
            }
            clearLiveCameraState()
            status = .cameraStarting
            detailText = "Starting camera."
            publishRuntimeDiagnostics(status: status, detail: detailText, metrics: nil)
            if !isPowerPaused {
                startCameraIfAllowed()
            }
        } else {
            guard cameraAuthorization == .authorized else {
                showPermissionSetupWindow()
                return
            }
            isManuallyPaused = true
            status = .paused
            detailText = "Monitoring is paused."
            publishRuntimeDiagnostics(status: status, detail: detailText, metrics: latestMetrics)
            nudger.clear()
            stopCamera()
        }
    }

    func snooze(minutes: Int) {
        guard cameraAuthorization == .authorized else {
            showPermissionSetupWindow()
            return
        }
        snoozeUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        status = .snoozed
        detailText = "Monitoring resumes at \(snoozeUntil!.formatted(date: .omitted, time: .shortened))."
        publishRuntimeDiagnostics(status: status, detail: detailText, metrics: latestMetrics)
        nudger.clear()
        stopCamera()
    }

    func testNudge() {
        if settings.notificationsEnabled {
            switch notificationPermissionStatus {
            case .notDetermined:
                requestProvisionalNotificationPermissionIfNeeded { [weak self] in
                    self?.fireTestNudge()
                }
                return
            case .denied:
                detailText = "Notifications are off. Sound and screen glow still work."
            case .requesting, .provisional, .authorized:
                break
            }
        }

        fireTestNudge()
    }

    private func fireTestNudge() {
        if detailText?.hasPrefix("Notifications are off.") != true {
            detailText = "Testing notification, sound, and glow."
        }
        isNudgePreviewActive = true
        publishRuntimeDiagnostics(status: status, detail: detailText, metrics: latestMetrics)

        nudger.update(
            status: .slouching,
            notificationsEnabled: notificationNudgesEnabled,
            soundEnabled: settings.soundEnabled,
            overlayEnabled: settings.overlayEnabled
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.isNudgePreviewActive = false
            guard self.status != .slouching else { return }
            self.nudger.clear()
            self.detailText = self.hasBaseline ? nil : "Calibrate once while sitting upright."
            self.publishRuntimeDiagnostics(status: self.status, detail: self.detailText, metrics: self.latestMetrics)
        }
    }

    func setInspectorVisible(_ visible: Bool) {
        guard inspectorVisible != visible else {
            if visible {
                cameraController.forceNextFrame()
            }
            return
        }

        inspectorVisible = visible
        cameraController.forceNextFrame()

        if visible {
            guard
                cameraAuthorization == .authorized,
                !isManuallyPaused,
                status != .snoozed,
                status != .cameraPermissionNeeded,
                status != .cameraDenied,
                status != .cameraNoFrames,
                status != .cameraUnavailable
            else {
                return
            }

            startCameraIfAllowed()
        } else if isPowerPaused && !isManuallyPaused && status != .snoozed {
            stopCamera()
            nudger.clear()
            status = .paused
            detailText = powerPauseReason
            publishRuntimeDiagnostics(status: status, detail: detailText, metrics: latestMetrics)
        }
    }

    func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
            return
        }

        NSWorkspace.shared.open(url)
        startPermissionPolling()
    }

    func quit() {
        stopCamera()
        nudger.clear()
        NSApp.terminate(nil)
    }

    private func startCameraIfAllowed(expectFrames: Bool = true) {
        guard cameraAuthorization == .authorized else { return }
        cameraController.start()
        if expectFrames {
            scheduleCameraFrameFallback()
        }
    }

    private func stopCamera() {
        cameraFrameWaitID = nil
        cameraController.stop()
    }

    private func clearLiveCameraState() {
        latestFrameImage = nil
        latestPose = nil
        latestMetrics = nil
        postureScore = nil
        hasReliableTrackingSample = false
        metricHistory = []
        smoothedScore = nil
        lastScoreUpdateAt = nil
    }

    private func configureServices() {
        cameraController.sampleIntervalProvider = { [weak self] in
            guard let self else { return 1.5 }
            if self.calibrator.isCollecting {
                return 1.0 / 15.0
            }
            if self.inspectorVisible {
                return 1.0 / 15.0
            }
            return self.powerManager.currentSampleInterval
        }

        cameraController.onFrame = { [weak self] sampleBuffer in
            DispatchQueue.main.async {
                self?.markCameraFrameReceived()
            }
            self?.processFrame(sampleBuffer)
        }

        cameraController.onAuthorizationChange = { [weak self] authorization in
            DispatchQueue.main.async {
                self?.applyCameraAuthorization(authorization)
            }
        }

        cameraController.onAuthorizationRequestFinished = { [weak self] in
            DispatchQueue.main.async {
                self?.onCameraPermissionRequestFinished?()
            }
        }

        powerManager.onCaptureDesiredChange = { [weak self] shouldCapture, reason in
            DispatchQueue.main.async {
                self?.applyPowerCapturePreference(shouldCapture: shouldCapture, reason: reason)
            }
        }

        powerManager.start()
    }

    private func configureSettingsObservation() {
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        settings.$baseline
            .sink { [weak self] baseline in
                self?.analysisQueue.async {
                    self?.postureAnalyzer.baseline = baseline
                }
            }
            .store(in: &cancellables)
    }

    func refreshPermissionStatuses() {
        refreshNotificationPermissionStatus()
        cameraController.refreshAuthorizationAndConfigureIfAllowed()
    }

    func requestCameraPermission() {
        cameraController.requestAuthorizationAndConfigure()
        startPermissionPolling()
    }

    func requestProvisionalNotificationPermissionIfNeeded(completion: (() -> Void)? = nil) {
        guard settings.notificationsEnabled else {
            completion?()
            return
        }

        guard notificationPermissionStatus == .notDetermined else {
            completion?()
            return
        }

        notificationPermissionStatus = .requesting
        startPermissionPolling()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshNotificationPermissionStatus(completion: completion)
            }
        }
    }

    func requestNotificationPermissionIfNeeded() {
        requestProvisionalNotificationPermissionIfNeeded()
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }

        NSWorkspace.shared.open(url)
        startPermissionPolling()
    }

    func closePermissionSetup() {
        isPermissionSetupVisible = false
    }

    private func refreshNotificationPermissionStatus(completion: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status: NotificationPermissionStatus
            switch settings.authorizationStatus {
            case .authorized, .ephemeral:
                status = .authorized
            case .provisional:
                status = .provisional
            case .denied:
                status = .denied
            case .notDetermined:
                status = .notDetermined
            @unknown default:
                status = .denied
            }

            DispatchQueue.main.async {
                guard let self else { return }
                let nextStatus = self.notificationPermissionStatus == .requesting && status == .notDetermined
                    ? .requesting
                    : status
                self.notificationPermissionStatus = nextStatus
                completion?()
            }
        }
    }

    private func showPermissionSetupWindow() {
        isPermissionSetupVisible = true
    }

    private func closePermissionSetupIfSatisfied() {
        guard cameraAuthorization == .authorized else { return }
        isPermissionSetupVisible = false
        if notificationPermissionStatus != .requesting {
            stopPermissionPolling()
        }
    }

    private func startPermissionPolling() {
        permissionPollingTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatuses()
        }
        permissionPollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPermissionPolling() {
        permissionPollingTimer?.invalidate()
        permissionPollingTimer = nil
    }

    private func scheduleCameraFrameFallback() {
        let waitID = UUID()
        cameraFrameWaitID = waitID

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard
                let self,
                self.cameraFrameWaitID == waitID,
                self.cameraAuthorization == .authorized,
                !self.isManuallyPaused,
                !self.isPowerPaused
            else {
                return
            }

            self.status = .cameraNoFrames
            self.detailText = "Camera access is enabled, but no frames are arriving. Quit other camera apps or restart Sloucher."
            self.clearLiveCameraState()
            self.publishRuntimeDiagnostics(status: self.status, detail: self.detailText, metrics: nil)
        }
    }

    private func markCameraFrameReceived() {
        cameraFrameWaitID = nil
        if status == .cameraNoFrames {
            status = .cameraStarting
            detailText = "Camera frame received. Measuring posture."
            publishRuntimeDiagnostics(status: status, detail: detailText, metrics: nil)
        }
    }

    private func processFrame(_ sampleBuffer: CMSampleBuffer) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let isCalibrating = self.calibrator.isCollecting
            let collectTrackingDiagnostics = !isCalibrating && self.hasBaseline
            let forceInference = isCalibrating || self.inspectorVisible
            let frameImage = self.makeFrameImage(from: sampleBuffer)
            let pixelBufferDiagnostics = Self.pixelBufferDiagnostics(from: sampleBuffer)
            let frameIdentityDiagnostics = Self.frameIdentityDiagnostics(from: sampleBuffer)
            let result = self.postureAnalyzer.analyze(
                sampleBuffer: sampleBuffer,
                config: self.settings.decisionConfig,
                forceInference: forceInference,
                collectCalibrationDiagnostics: isCalibrating,
                collectTrackingDiagnostics: collectTrackingDiagnostics
            )
            let frameDiagnostics = self.postureAnalyzer.lastFrameDiagnostics
            self.publishFrameDiagnostics(frameDiagnostics, result: result)
            self.publishPixelBufferDiagnostics(pixelBufferDiagnostics)
            self.publishFrameIdentityDiagnostics(frameIdentityDiagnostics)
            if collectTrackingDiagnostics, let pixelBufferDiagnostics {
                let trackingFrame = self.recordTrackingDiagnostics(
                    frameDiagnostics,
                    result: result,
                    pixelBufferDiagnostics: pixelBufferDiagnostics,
                    frameIdentityDiagnostics: frameIdentityDiagnostics
                )

                #if DEBUG
                // Forensic capture can store camera pixels on disk. Keep that
                // evidence path in debug builds only so shipped builds retain
                // numeric diagnostics without writing frame images/raw planes.
                self.updateForensicCapture(
                    trackingFrame: trackingFrame,
                    pixelBufferDiagnostics: pixelBufferDiagnostics,
                    frameDiagnostics: frameDiagnostics,
                    result: result,
                    sampleBuffer: sampleBuffer,
                    frameImage: frameImage
                )
                #endif
            }

            if let metrics = result.metrics, metrics.source == .body {
                self.rememberBodyCalibrationMetric(metrics)
            }

            var completedCalibration: PostureBaseline?
            var calibrationMetrics = result.metrics
            var calibrationSampleCount: Int?
            let requiredSampleCount = self.calibrator.requiredSampleCount

            if self.calibrator.isCollecting {
                self.calibrationFrames += 1
                // Keep aggregate Vision counts so a later successful calibration
                // does not erase whether failures were "no body observations" or
                // "body observations rejected by our filters."
                self.calibrationBodyObservationTotal += frameDiagnostics.bodyObservationCount
                self.calibrationValidBodyCandidateTotal += frameDiagnostics.validBodyCandidateCount
                if frameDiagnostics.faceDetected {
                    self.calibrationFaceDetectedFrames += 1
                }

                if result.metrics?.source == .body {
                    self.calibrationBodySuccesses += 1
                }

                if let metrics = result.metrics {
                    completedCalibration = self.calibrator.add(metrics: metrics)
                }

                if completedCalibration == nil {
                    completedCalibration = self.calibrator.finishIfReady()
                    calibrationMetrics = calibrationMetrics ?? self.calibrator.latestSample
                }

                calibrationSampleCount = self.calibrator.bodySampleCount
                self.runtimeDefaults.set(calibrationSampleCount ?? 0, forKey: RuntimeKeys.calibrationBodySamples)
                self.runtimeDefaults.set(self.calibrationFrames, forKey: RuntimeKeys.calibrationFrames)
                self.runtimeDefaults.set(self.calibrationBodySuccesses, forKey: RuntimeKeys.calibrationBodySuccesses)
                self.runtimeDefaults.set(self.calibrator.rejectedSampleCount, forKey: RuntimeKeys.calibrationRejectedSamples)
                self.runtimeDefaults.set(frameDiagnostics.bodyObservationCount, forKey: RuntimeKeys.calibrationBodyObservationCount)
                self.runtimeDefaults.set(frameDiagnostics.validBodyCandidateCount, forKey: RuntimeKeys.calibrationValidBodyCandidateCount)
                self.runtimeDefaults.set(frameDiagnostics.faceDetected, forKey: RuntimeKeys.calibrationFaceDetected)
                self.runtimeDefaults.set(self.calibrationBodyObservationTotal, forKey: RuntimeKeys.calibrationBodyObservationTotal)
                self.runtimeDefaults.set(self.calibrationValidBodyCandidateTotal, forKey: RuntimeKeys.calibrationValidBodyCandidateTotal)
                self.runtimeDefaults.set(self.calibrationFaceDetectedFrames, forKey: RuntimeKeys.calibrationFaceDetectedFrames)
                self.setRuntime(frameDiagnostics.candidateConfidence, forKey: RuntimeKeys.calibrationLastCandidateConfidence)
                self.setRuntime(frameDiagnostics.candidateShoulderWidth, forKey: RuntimeKeys.calibrationLastCandidateShoulderWidth)
                self.setRuntime(frameDiagnostics.candidateNeckDistance, forKey: RuntimeKeys.calibrationLastCandidateNeckDistance)
                self.setRuntime(frameDiagnostics.bestCandidateScore, forKey: RuntimeKeys.calibrationLastCandidateScore)
                self.setRuntime(frameDiagnostics.headAnchorSource, forKey: RuntimeKeys.calibrationHeadAnchorSource)

                if !frameDiagnostics.orientationSweepResults.isEmpty {
                    // Store every tested orientation for a few failing calibration
                    // frames. The best orientation is only a quick summary; the
                    // full sweep is the evidence for or against an orientation bug.
                    let sweep = PostureOrientationSweepDiagnostics(
                        frame: self.calibrationFrames,
                        timestamp: Date(),
                        results: frameDiagnostics.orientationSweepResults,
                        bestOrientation: Self.bestOrientationName(in: frameDiagnostics.orientationSweepResults)
                    )
                    self.calibrationDebugOrientationSweeps.append(sweep)
                    self.calibrationDebugOrientationSweeps = Array(self.calibrationDebugOrientationSweeps.suffix(3))
                    self.publishCalibrationDebugOrientationSweeps()
                }

                self.setRuntime(result.reason, forKey: RuntimeKeys.calibrationLastFailure)
                self.setRuntime(frameDiagnostics.bodyFailureReason, forKey: RuntimeKeys.calibrationLastBodyFailure)
                self.setRuntime(self.calibrator.lastRejectReason, forKey: RuntimeKeys.calibrationLastRejectReason)

                let rawIssue = self.calibrator.lastRejectReason ??
                    result.reason ??
                    frameDiagnostics.bodyFailureReason
                let issue = rawIssue.map {
                    Self.trackingGuidance(faceDetected: frameDiagnostics.faceDetected, detail: $0)
                }
                let frameCount = self.calibrationFrames

                DispatchQueue.main.async {
                    self.calibrationBodySamples = calibrationSampleCount ?? 0
                    self.calibrationRequiredSamples = requiredSampleCount
                    self.calibrationFrameCount = frameCount
                    self.calibrationLastIssue = issue
                }
            }

            if let baseline = completedCalibration {
                self.postureAnalyzer.baseline = baseline
                let sampleCount = calibrationSampleCount ?? self.calibrator.bodySampleCount
                let frameCount = self.calibrationFrames
                let rejectedSampleCount = self.calibrator.rejectedSampleCount
                self.publishCalibrationAttemptSnapshot(
                    prefix: RuntimeKeys.calibrationLastAttemptPrefix,
                    status: "succeeded",
                    bodySamples: sampleCount,
                    bodySuccesses: self.calibrationBodySuccesses,
                    frames: frameCount,
                    rejectedSamples: rejectedSampleCount,
                    reason: nil
                )
                self.publishCalibrationAttemptSnapshot(
                    prefix: RuntimeKeys.calibrationLastSucceededPrefix,
                    status: "succeeded",
                    bodySamples: sampleCount,
                    bodySuccesses: self.calibrationBodySuccesses,
                    frames: frameCount,
                    rejectedSamples: rejectedSampleCount,
                    reason: nil
                )

                DispatchQueue.main.async {
                    self.settings.baseline = baseline
                    self.status = .good
                    self.detailText = "Calibrated."

                    if let calibrationMetrics {
                        self.updatePostureScore(with: calibrationMetrics, status: .good)
                        self.latestMetrics = calibrationMetrics
                    }

                    self.latestPose = result.pose
                    self.latestFrameImage = frameImage
                    self.lastFrameDiagnostics = frameDiagnostics
                    self.metricHistory = []
                    self.calibrationBodySamples = sampleCount
                    self.calibrationFrameCount = frameCount
                    self.calibrationLastIssue = nil
                    self.runtimeDefaults.set(sampleCount, forKey: RuntimeKeys.calibrationBodySamples)
                    self.runtimeDefaults.removeObject(forKey: RuntimeKeys.calibrationLastFailure)
                    self.publishRuntimeDiagnostics(
                        status: self.status,
                        detail: self.detailText,
                        metrics: calibrationMetrics ?? self.latestMetrics
                    )
                    self.cameraController.forceNextFrame()
                }

                return
            }

            if self.calibrator.hasTimedOut(collectionTimeout: 7, noSampleTimeout: 12) {
                let bodySampleCount = self.calibrator.bodySampleCount
                let rejectedSampleCount = self.calibrator.rejectedSampleCount
                let lastRejectReason = self.calibrator.lastRejectReason
                let frameCount = self.calibrationFrames
                let bodySuccessCount = self.calibrationBodySuccesses
                let lastIssue = lastRejectReason ?? self.runtimeDefaults.string(forKey: RuntimeKeys.calibrationLastBodyFailure)
                let guidance = lastIssue.map {
                    Self.trackingGuidance(faceDetected: frameDiagnostics.faceDetected, detail: $0)
                }
                self.publishCalibrationAttemptSnapshot(
                    prefix: RuntimeKeys.calibrationLastAttemptPrefix,
                    status: "failed",
                    bodySamples: bodySampleCount,
                    bodySuccesses: bodySuccessCount,
                    frames: frameCount,
                    rejectedSamples: rejectedSampleCount,
                    reason: guidance
                )
                self.publishCalibrationAttemptSnapshot(
                    prefix: RuntimeKeys.calibrationLastFailedPrefix,
                    status: "failed",
                    bodySamples: bodySampleCount,
                    bodySuccesses: bodySuccessCount,
                    frames: frameCount,
                    rejectedSamples: rejectedSampleCount,
                    reason: guidance
                )
                self.calibrator.cancel()
                DispatchQueue.main.async {
                    self.status = self.hasBaseline ? .good : .cannotSee
                    self.detailText = Self.calibrationFailureMessage(
                        bodySamples: bodySampleCount,
                        bodySuccesses: bodySuccessCount,
                        frames: frameCount,
                        lastIssue: guidance
                    )
                    self.calibrationBodySamples = bodySampleCount
                    self.calibrationFrameCount = frameCount
                    self.calibrationLastIssue = guidance
                    self.postureScore = nil
                    self.lastFrameDiagnostics = frameDiagnostics
                    self.runtimeDefaults.set(
                        bodySampleCount,
                        forKey: RuntimeKeys.calibrationBodySamples
                    )
                    self.runtimeDefaults.set(frameCount, forKey: RuntimeKeys.calibrationFrames)
                    self.runtimeDefaults.set(bodySuccessCount, forKey: RuntimeKeys.calibrationBodySuccesses)
                    self.runtimeDefaults.set(rejectedSampleCount, forKey: RuntimeKeys.calibrationRejectedSamples)
                    self.publishRuntimeDiagnostics(status: self.status, detail: self.detailText, metrics: self.latestMetrics)
                    self.cameraController.forceNextFrame()
                }
                return
            }

            DispatchQueue.main.async {
                self.latestFrameImage = frameImage
                self.lastFrameDiagnostics = frameDiagnostics
                self.applyAnalysisResult(result)
            }
        }
    }

    private func applyAnalysisResult(_ result: PostureAnalysisResult) {
        guard !isManuallyPaused && (!isPowerPaused || inspectorVisible) && status != .calibrating else {
            if let metrics = result.metrics {
                latestMetrics = metrics
            }
            if let pose = result.pose {
                latestPose = pose
            }
            return
        }

        if let snoozeUntil {
            if Date() < snoozeUntil {
                status = .snoozed
                return
            }
            self.snoozeUntil = nil
            startCameraIfAllowed()
        }

        let wasWaitingForFirstFrame = status == .cameraStarting || status == .cameraNoFrames
        let hasCurrentMetrics = result.metrics != nil
        // The analyzer carries a previous posture state through unreliable
        // frames. On startup there is no previous reliable sample, so do not
        // let that fallback appear as "Good posture" before metrics exist.
        let nextStatus: PostureStatus
        if hasBaseline {
            if hasCurrentMetrics || hasReliableTrackingSample {
                nextStatus = result.status
            } else if result.reason != nil {
                nextStatus = .cannotSee
            } else {
                nextStatus = .cameraStarting
            }
        } else {
            nextStatus = .uncalibrated
        }
        if let metrics = result.metrics {
            latestMetrics = metrics
            hasReliableTrackingSample = true
        } else if nextStatus == .cannotSee {
            latestMetrics = nil
        }
        if let pose = result.pose {
            latestPose = pose
        } else if nextStatus == .cannotSee {
            latestPose = nil
        }

        status = nextStatus
        if nextStatus == .cannotSee || result.metrics == nil, let reason = result.reason {
            detailText = Self.trackingGuidance(
                faceDetected: lastFrameDiagnostics.faceDetected,
                detail: lastFrameDiagnostics.bodyFailureReason ?? reason
            )
        } else if hasBaseline {
            detailText = result.reason
        } else if let reason = result.reason {
            detailText = Self.trackingGuidance(
                faceDetected: lastFrameDiagnostics.faceDetected,
                detail: lastFrameDiagnostics.bodyFailureReason ?? reason
            )
        } else if detailText?.hasPrefix("Couldn't calibrate.") == true {
            // Preserve actionable calibration failure guidance until the next attempt.
        } else {
            detailText = "Click Calibrate once your head and both shoulders are visible."
        }

        if let metrics = result.metrics {
            updatePostureScore(with: metrics, status: nextStatus)
            recordHistory(metrics: metrics, status: nextStatus)
        } else if nextStatus == .cannotSee || nextStatus == .uncalibrated {
            postureScore = nil
        }

        publishRuntimeDiagnostics(status: nextStatus, detail: detailText, metrics: liveMetrics)
        if wasWaitingForFirstFrame {
            showCalibrationHintIfNeeded()
        }

        if nextStatus == .slouching {
            requestProvisionalNotificationPermissionIfNeeded()
        }

        nudger.update(
            status: nextStatus,
            notificationsEnabled: notificationNudgesEnabled,
            soundEnabled: settings.soundEnabled,
            overlayEnabled: settings.overlayEnabled
        )
    }

    private func applyCameraAuthorization(_ authorization: CameraAuthorization) {
        let previousAuthorization = cameraAuthorization
        let isInitialPermissionCheck = !hasCheckedCameraAuthorization
        cameraAuthorization = authorization
        hasCheckedCameraAuthorization = true

        switch authorization {
        case .notDetermined:
            stopCamera()
            status = .cameraPermissionNeeded
            detailText = "Camera access is required to measure posture."
            postureScore = nil
            publishRuntimeDiagnostics(status: status, detail: detailText, metrics: nil)
            showPermissionSetupWindow()
        case .requesting:
            stopCamera()
            status = .cameraPermissionNeeded
            detailText = "Waiting for camera permission."
            postureScore = nil
            publishRuntimeDiagnostics(status: status, detail: detailText, metrics: nil)
        case .authorized:
            closePermissionSetupIfSatisfied()
            // Settings polling can report authorized repeatedly; do not reset a
            // live session back to startup unless we are recovering from no frames.
            guard previousAuthorization != .authorized || status == .cameraNoFrames else {
                return
            }
            clearLiveCameraState()
            status = .cameraStarting
            detailText = "Starting camera."
            publishRuntimeDiagnostics(status: status, detail: detailText, metrics: nil)
            startCameraIfAllowed()
            requestProvisionalNotificationPermissionIfNeeded()
            onCameraPermissionSatisfied?()
        case .denied:
            stopCamera()
            status = .cameraDenied
            detailText = "Allow camera access in System Settings."
            postureScore = nil
            publishRuntimeDiagnostics(status: status, detail: detailText, metrics: nil)
            showPermissionSetupWindow()
        case .unavailable:
            stopCamera()
            status = .cameraUnavailable
            detailText = "No video camera was found."
            postureScore = nil
            publishRuntimeDiagnostics(status: status, detail: detailText, metrics: nil)
            showPermissionSetupWindow()
        }

        if isInitialPermissionCheck && authorization != .authorized {
            onInitialBlockingPermissionNeeded?()
        }
    }

    private func applyPowerCapturePreference(shouldCapture: Bool, reason: String?) {
        isPowerPaused = !shouldCapture
        powerPauseReason = reason

        if shouldCapture {
            guard cameraAuthorization == .authorized else { return }
            guard !isManuallyPaused && status != .snoozed else { return }
            clearLiveCameraState()
            startCameraIfAllowed()
            status = .cameraStarting
            detailText = "Starting camera."
            publishRuntimeDiagnostics(status: status, detail: detailText, metrics: nil)
        } else {
            guard !inspectorVisible else { return }
            stopCamera()
            nudger.clear()
            if !isManuallyPaused && status != .snoozed {
                status = .paused
                detailText = reason
                publishRuntimeDiagnostics(status: status, detail: detailText, metrics: latestMetrics)
            }
        }
    }

    private func makeFrameImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return imageContext.createCGImage(image, from: image.extent)
    }

    private func updatePostureScore(with metrics: PostureMetrics, status: PostureStatus) {
        guard
            status != .calibrating,
            status != .cannotSee,
            let baseline = displayBaselineDistance,
            baseline.isFinite,
            baseline > 0
        else {
            postureScore = nil
            smoothedScore = nil
            lastScoreUpdateAt = nil
            return
        }

        let dropFraction = max(0, (baseline - metrics.neckDistance) / baseline)
        let leanFraction = max(0, metrics.closeness - 1)
        let penalty = 100 * max(dropFraction / 0.30, 0.6 * leanFraction / 0.25)
        let rawScore = min(100, max(0, 100 - penalty))
        let now = metrics.timestamp
        let alpha: Double

        if let lastScoreUpdateAt {
            let elapsed = max(0, now.timeIntervalSince(lastScoreUpdateAt))
            alpha = 1 - exp(-elapsed / 0.4)
        } else {
            alpha = 1
        }

        let current = smoothedScore ?? rawScore
        let nextScore = current + alpha * (rawScore - current)
        smoothedScore = nextScore
        lastScoreUpdateAt = now
        postureScore = min(100, max(0, Int(nextScore.rounded())))
    }

    private func recordHistory(metrics: PostureMetrics, status: PostureStatus) {
        guard metrics.neckDistance.isFinite else { return }

        metricHistory.append(
            MetricHistorySample(
                timestamp: metrics.timestamp,
                neckDistance: metrics.neckDistance,
                wasSlouching: status == .slouching
            )
        )

        let cutoff = metrics.timestamp.addingTimeInterval(-12)
        metricHistory.removeAll { $0.timestamp < cutoff }
    }

    private func rememberBodyCalibrationMetric(_ metrics: PostureMetrics) {
        guard
            metrics.neckDistance.isFinite,
            metrics.neckDistance > 0,
            metrics.shoulderWidth.isFinite,
            metrics.shoulderWidth >= 0.12,
            metrics.confidence >= 0.3
        else {
            return
        }

        recentBodyCalibrationMetrics.append(metrics)
        let cutoff = metrics.timestamp.addingTimeInterval(-4)
        recentBodyCalibrationMetrics.removeAll { $0.timestamp < cutoff }

        if recentBodyCalibrationMetrics.count > 90 {
            recentBodyCalibrationMetrics.removeFirst(recentBodyCalibrationMetrics.count - 90)
        }
    }

    private static func trackingGuidance(faceDetected: Bool, detail: String?) -> String {
        let detail = detail ?? ""

        if detail.localizedCaseInsensitiveContains("move back") ||
            detail.localizedCaseInsensitiveContains("shoulder width") {
            return "Move back a little so both shoulders fit in the camera view."
        }

        if detail.localizedCaseInsensitiveContains("left shoulder") {
            return faceDetected
                ? "Face is visible. Bring your left shoulder into view."
                : "Bring your head and left shoulder into view."
        }

        if detail.localizedCaseInsensitiveContains("right shoulder") {
            return faceDetected
                ? "Face is visible. Bring your right shoulder into view."
                : "Bring your head and right shoulder into view."
        }

        if detail.localizedCaseInsensitiveContains("confidence") ||
            detail.localizedCaseInsensitiveContains("unreliable") ||
            detail.localizedCaseInsensitiveContains("hold still") {
            return "Hold still for a moment so Sloucher can measure your posture."
        }

        if faceDetected {
            return "Face is visible. Bring both shoulders into view so Sloucher can measure posture."
        }

        return "Move into view with your head and both shoulders visible."
    }

    private static func calibrationFailureMessage(
        bodySamples: Int,
        bodySuccesses: Int,
        frames: Int,
        lastIssue: String?
    ) -> String {
        let issue = lastIssue.map { " \($0)" } ?? ""

        if bodySuccesses == 0 {
            return "Couldn't calibrate. Vision did not return a usable upper-body pose in \(frames) frames.\(issue)"
        }

        return "Couldn't calibrate. Collected \(bodySamples) valid samples from \(bodySuccesses) body frames; need more stable head and shoulder tracking.\(issue)"
    }

    private func showCalibrationHintIfNeeded() {
        guard !hasBaseline else { return }
        guard !runtimeDefaults.bool(forKey: RuntimeKeys.didShowCalibrationHint) else { return }
        runtimeDefaults.set(true, forKey: RuntimeKeys.didShowCalibrationHint)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.hasBaseline else { return }

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Calibrate Sloucher once"
            alert.informativeText = "The camera is on, but posture alerts need a baseline. Sit upright, click the Sloucher menu-bar icon, then choose Calibrate."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func publishRuntimeDiagnostics(
        status: PostureStatus,
        detail: String?,
        metrics: PostureMetrics?
    ) {
        runtimeDefaults.set(status.rawValue, forKey: RuntimeKeys.status)
        runtimeDefaults.set(status.displayName, forKey: RuntimeKeys.statusDisplayName)
        setRuntime(detail, forKey: RuntimeKeys.detail)
        runtimeDefaults.set(hasBaseline, forKey: RuntimeKeys.hasBaseline)
        runtimeDefaults.set(Date(), forKey: RuntimeKeys.updatedAt)

        if let baseline = settings.baseline {
            runtimeDefaults.set(baseline.neckDistance, forKey: RuntimeKeys.baselineNeckDistance)
            runtimeDefaults.set(baseline.shoulderWidth, forKey: RuntimeKeys.baselineShoulderWidth)
            setRuntime(baseline.faceCenterY, forKey: RuntimeKeys.baselineFaceCenterY)
            setRuntime(baseline.faceWidth, forKey: RuntimeKeys.baselineFaceWidth)
            runtimeDefaults.set(baseline.primarySource.rawValue, forKey: RuntimeKeys.baselinePrimarySource)
        } else {
            runtimeDefaults.removeObject(forKey: RuntimeKeys.baselineNeckDistance)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.baselineShoulderWidth)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.baselineFaceCenterY)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.baselineFaceWidth)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.baselinePrimarySource)
        }

        if let metrics {
            runtimeDefaults.set(metrics.source.rawValue, forKey: RuntimeKeys.metricSource)
            runtimeDefaults.set(metrics.neckDistance, forKey: RuntimeKeys.metricNeckDistance)
            runtimeDefaults.set(metrics.shoulderWidth, forKey: RuntimeKeys.metricShoulderWidth)
            runtimeDefaults.set(metrics.closeness, forKey: RuntimeKeys.metricCloseness)
            setRuntime(metrics.faceCenterY, forKey: RuntimeKeys.metricFaceCenterY)
            setRuntime(metrics.faceWidth, forKey: RuntimeKeys.metricFaceWidth)
            runtimeDefaults.set(Double(metrics.confidence), forKey: RuntimeKeys.metricConfidence)
            runtimeDefaults.set(metrics.timestamp, forKey: RuntimeKeys.metricTimestamp)
        } else {
            runtimeDefaults.removeObject(forKey: RuntimeKeys.metricSource)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.metricNeckDistance)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.metricShoulderWidth)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.metricCloseness)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.metricFaceCenterY)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.metricFaceWidth)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.metricConfidence)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.metricTimestamp)
        }
    }

    private func publishCalibrationAttemptSnapshot(
        prefix: String,
        status: String,
        bodySamples: Int,
        bodySuccesses: Int,
        frames: Int,
        rejectedSamples: Int,
        reason: String?
    ) {
        runtimeDefaults.set(status, forKey: "\(prefix).status")
        runtimeDefaults.set(Date(), forKey: "\(prefix).finishedAt")
        runtimeDefaults.set(bodySamples, forKey: "\(prefix).bodySamples")
        runtimeDefaults.set(bodySuccesses, forKey: "\(prefix).bodySuccesses")
        runtimeDefaults.set(frames, forKey: "\(prefix).frames")
        runtimeDefaults.set(rejectedSamples, forKey: "\(prefix).rejectedSamples")
        runtimeDefaults.set(calibrationBodyObservationTotal, forKey: "\(prefix).bodyObservationTotal")
        runtimeDefaults.set(calibrationValidBodyCandidateTotal, forKey: "\(prefix).validBodyCandidateTotal")
        runtimeDefaults.set(calibrationFaceDetectedFrames, forKey: "\(prefix).faceDetectedFrames")
        setRuntime(reason, forKey: "\(prefix).reason")
    }

    private func publishCalibrationDebugOrientationSweeps() {
        guard let json = Self.jsonString(calibrationDebugOrientationSweeps) else {
            runtimeDefaults.removeObject(forKey: RuntimeKeys.calibrationDebugOrientationSweeps)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.calibrationDebugBestOrientation)
            return
        }

        runtimeDefaults.set(json, forKey: RuntimeKeys.calibrationDebugOrientationSweeps)
        setRuntime(
            calibrationDebugOrientationSweeps.last?.bestOrientation,
            forKey: RuntimeKeys.calibrationDebugBestOrientation
        )
    }

    private func recordTrackingDiagnostics(
        _ diagnostics: PostureFrameDiagnostics,
        result: PostureAnalysisResult,
        pixelBufferDiagnostics: PosturePixelBufferDiagnostics,
        frameIdentityDiagnostics: PostureFrameIdentityDiagnostics?
    ) -> PostureTrackingFrameDiagnostics {
        trackingDebugFrameNumber += 1

        // Keep successful and failed live frames in the same window because the
        // bug is the transition from a valid calibration to unusable tracking.
        let frame = PostureTrackingFrameDiagnostics(
            frame: trackingDebugFrameNumber,
            timestamp: Date(),
            presentationTimeSeconds: pixelBufferDiagnostics.presentationTimeSeconds,
            lumaSampleHash: frameIdentityDiagnostics?.lumaSampleHash,
            lumaSampleChecksum: frameIdentityDiagnostics?.lumaSampleChecksum,
            status: result.status.rawValue,
            acceptedFrame: result.acceptedFrame,
            reason: result.reason,
            bodyObservationCount: diagnostics.bodyObservationCount,
            validBodyCandidateCount: diagnostics.validBodyCandidateCount,
            bodyObservations: diagnostics.bodyObservations,
            faceDetected: diagnostics.faceDetected,
            faceObservationCount: diagnostics.faceObservationCount,
            faceBox: diagnostics.faceBox,
            faceConfidence: diagnostics.faceConfidence,
            candidateConfidence: diagnostics.candidateConfidence,
            candidateShoulderWidth: diagnostics.candidateShoulderWidth,
            candidateNeckDistance: diagnostics.candidateNeckDistance,
            rawNoseConfidence: diagnostics.rawNoseConfidence,
            rawLeftShoulderConfidence: diagnostics.rawLeftShoulderConfidence,
            rawRightShoulderConfidence: diagnostics.rawRightShoulderConfidence,
            rawShoulderWidth: diagnostics.rawShoulderWidth,
            rawRejectReason: diagnostics.rawRejectReason,
            metricShoulderWidth: result.metrics?.shoulderWidth,
            metricNeckDistance: result.metrics?.neckDistance,
            metricCloseness: result.metrics?.closeness,
            forceInference: diagnostics.forceInference,
            motionGateSkipped: diagnostics.motionGateSkipped,
            motionGateMeanAbsoluteDifference: diagnostics.motionGateMeanAbsoluteDifference,
            motionGateThreshold: diagnostics.motionGateThreshold,
            motionGateHadPreviousFrame: diagnostics.motionGateHadPreviousFrame,
            motionGateFrameHash: diagnostics.motionGateFrameHash,
            consecutiveFailureFrameCount: diagnostics.consecutiveFailureFrameCount,
            forcedVisionAttemptsSinceFailure: diagnostics.forcedVisionAttemptsSinceFailure,
            orientationRetryBestOrientation: diagnostics.orientationRetryBestOrientation,
            orientationRetryBestValidCandidateCount: diagnostics.orientationRetryBestValidCandidateCount,
            orientationRetryUpMirroredValidCandidateCount: diagnostics.orientationRetryUpMirroredValidCandidateCount,
            orientationRetryUpMirroredShoulderWidth: diagnostics.orientationRetryUpMirroredShoulderWidth,
            orientationRetryUpMirroredRejectReason: diagnostics.orientationRetryUpMirroredRejectReason
        )

        trackingDebugFrames.append(frame)
        trackingDebugFrames = Array(trackingDebugFrames.suffix(60))

        if !diagnostics.orientationSweepResults.isEmpty {
            let sweep = PostureOrientationSweepDiagnostics(
                frame: trackingDebugFrameNumber,
                timestamp: Date(),
                results: diagnostics.orientationSweepResults,
                bestOrientation: Self.bestOrientationName(in: diagnostics.orientationSweepResults)
            )
            trackingDebugOrientationSweeps.append(sweep)
            trackingDebugOrientationSweeps = Array(trackingDebugOrientationSweeps.suffix(5))
            publishTrackingDebugOrientationSweeps()
        }

        publishTrackingDebugFrames()
        return frame
    }

    private func publishTrackingDebugFrames() {
        guard !trackingDebugFrames.isEmpty else {
            runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugFrames)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugSummary)
            return
        }

        let summary = Self.trackingSummary(from: trackingDebugFrames)
        setRuntime(Self.jsonString(trackingDebugFrames), forKey: RuntimeKeys.trackingDebugFrames)
        setRuntime(Self.jsonString(summary), forKey: RuntimeKeys.trackingDebugSummary)
        runtimeDefaults.set(summary.frameCount, forKey: RuntimeKeys.trackingDebugWindowFrames)
        runtimeDefaults.set(summary.acceptedFrameCount, forKey: RuntimeKeys.trackingDebugAcceptedFrames)
        runtimeDefaults.set(summary.faceDetectedFrameCount, forKey: RuntimeKeys.trackingDebugFaceDetectedFrames)
        runtimeDefaults.set(summary.bodyObservationFrameCount, forKey: RuntimeKeys.trackingDebugBodyObservationFrames)
        runtimeDefaults.set(summary.validCandidateFrameCount, forKey: RuntimeKeys.trackingDebugValidCandidateFrames)
        runtimeDefaults.set(summary.noBodyObservationFrameCount, forKey: RuntimeKeys.trackingDebugNoBodyObservationFrames)
        runtimeDefaults.set(summary.invalidBodyCandidateFrameCount, forKey: RuntimeKeys.trackingDebugInvalidCandidateFrames)
        runtimeDefaults.set(summary.motionSkippedFrameCount, forKey: RuntimeKeys.trackingDebugMotionSkippedFrames)
        runtimeDefaults.set(summary.forcedInferenceFrameCount, forKey: RuntimeKeys.trackingDebugForcedInferenceFrames)
        runtimeDefaults.set(summary.uniqueLumaHashCount, forKey: RuntimeKeys.trackingDebugUniqueLumaHashes)
        setRuntime(
            summary.latestPresentationTimeSeconds,
            forKey: RuntimeKeys.trackingDebugLatestPresentationTimeSeconds
        )
        setRuntime(summary.latestStatus, forKey: RuntimeKeys.trackingDebugLatestStatus)
        setRuntime(summary.latestRejectReason, forKey: RuntimeKeys.trackingDebugLatestRejectReason)
        setRuntime(summary.rawShoulderWidthMin, forKey: RuntimeKeys.trackingDebugRawShoulderWidthMin)
        setRuntime(summary.rawShoulderWidthMedian, forKey: RuntimeKeys.trackingDebugRawShoulderWidthMedian)
        setRuntime(summary.rawShoulderWidthMax, forKey: RuntimeKeys.trackingDebugRawShoulderWidthMax)
        setRuntime(summary.metricShoulderWidthMin, forKey: RuntimeKeys.trackingDebugMetricShoulderWidthMin)
        setRuntime(summary.metricShoulderWidthMedian, forKey: RuntimeKeys.trackingDebugMetricShoulderWidthMedian)
        setRuntime(summary.metricShoulderWidthMax, forKey: RuntimeKeys.trackingDebugMetricShoulderWidthMax)
    }

    private func publishTrackingDebugOrientationSweeps() {
        guard let json = Self.jsonString(trackingDebugOrientationSweeps) else {
            runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugOrientationSweeps)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugBestOrientation)
            return
        }

        runtimeDefaults.set(json, forKey: RuntimeKeys.trackingDebugOrientationSweeps)
        setRuntime(
            trackingDebugOrientationSweeps.last?.bestOrientation,
            forKey: RuntimeKeys.trackingDebugBestOrientation
        )
    }

    private func resetTrackingDebugDiagnostics() {
        trackingDebugFrames = []
        trackingDebugFrameNumber = 0
        trackingDebugOrientationSweeps = []
        lastValidForensicFrame = nil
        pendingForensicCollapse = nil
        nextForensicCaptureAllowedAt = .distantPast
        postureAnalyzer.resetTrackingDebugDiagnostics()
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugFrames)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugSummary)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugOrientationSweeps)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugBestOrientation)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugWindowFrames)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugAcceptedFrames)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugFaceDetectedFrames)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugBodyObservationFrames)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugValidCandidateFrames)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugNoBodyObservationFrames)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugInvalidCandidateFrames)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugMotionSkippedFrames)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugForcedInferenceFrames)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugUniqueLumaHashes)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugLatestPresentationTimeSeconds)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugLatestStatus)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugLatestRejectReason)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugRawShoulderWidthMin)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugRawShoulderWidthMedian)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugRawShoulderWidthMax)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugMetricShoulderWidthMin)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugMetricShoulderWidthMedian)
        runtimeDefaults.removeObject(forKey: RuntimeKeys.trackingDebugMetricShoulderWidthMax)
    }

    private func updateForensicCapture(
        trackingFrame: PostureTrackingFrameDiagnostics,
        pixelBufferDiagnostics: PosturePixelBufferDiagnostics,
        frameDiagnostics: PostureFrameDiagnostics,
        result: PostureAnalysisResult,
        sampleBuffer: CMSampleBuffer,
        frameImage: CGImage?
    ) {
        guard Date() >= nextForensicCaptureAllowedAt else { return }

        let collapsed = isCollapsedShoulderFrame(trackingFrame, diagnostics: frameDiagnostics)
        let recovered = result.acceptedFrame && pendingForensicCollapse != nil

        if result.acceptedFrame {
            let snapshot = makeForensicSnapshot(
                trackingFrame: trackingFrame,
                pixelBufferDiagnostics: pixelBufferDiagnostics,
                frameDiagnostics: frameDiagnostics,
                sampleBuffer: sampleBuffer,
                frameImage: frameImage
            )

            if recovered {
                saveForensicSequence(recoveryFrame: snapshot)
                pendingForensicCollapse = nil
                nextForensicCaptureAllowedAt = Date().addingTimeInterval(20)
            }

            lastValidForensicFrame = snapshot
            return
        }

        guard collapsed, pendingForensicCollapse == nil else { return }

        // Capture the first collapsed-shoulder frame. The paired recovery frame
        // proves what changed in the input when a tiny movement reacquires pose.
        pendingForensicCollapse = makeForensicSnapshot(
            trackingFrame: trackingFrame,
            pixelBufferDiagnostics: pixelBufferDiagnostics,
            frameDiagnostics: frameDiagnostics,
            sampleBuffer: sampleBuffer,
            frameImage: frameImage
        )
    }

    private func isCollapsedShoulderFrame(
        _ frame: PostureTrackingFrameDiagnostics,
        diagnostics: PostureFrameDiagnostics
    ) -> Bool {
        guard
            frame.faceDetected,
            !frame.acceptedFrame,
            frame.bodyObservationCount > 0,
            frame.validBodyCandidateCount == 0,
            let rawShoulderWidth = frame.rawShoulderWidth,
            let baselineShoulderWidth = settings.baseline?.shoulderWidth,
            baselineShoulderWidth.isFinite,
            baselineShoulderWidth > 0
        else {
            return false
        }

        let leftConfidence = frame.rawLeftShoulderConfidence ?? 0
        let rightConfidence = frame.rawRightShoulderConfidence ?? 0
        let collapsedRelativeToBaseline = rawShoulderWidth < baselineShoulderWidth * 0.45

        return collapsedRelativeToBaseline &&
            rawShoulderWidth < 0.12 &&
            max(leftConfidence, rightConfidence) >= 0.5 &&
            diagnostics.bodyFailureReason?.localizedCaseInsensitiveContains("move back") == true
    }

    private func makeForensicSnapshot(
        trackingFrame: PostureTrackingFrameDiagnostics,
        pixelBufferDiagnostics: PosturePixelBufferDiagnostics,
        frameDiagnostics: PostureFrameDiagnostics,
        sampleBuffer: CMSampleBuffer,
        frameImage: CGImage?
    ) -> ForensicFrameSnapshot {
        ForensicFrameSnapshot(
            trackingFrame: trackingFrame,
            pixelBuffer: pixelBufferDiagnostics,
            image: frameImage,
            rawPlanes: Self.rawPlaneDumps(from: sampleBuffer),
            bodyObservations: frameDiagnostics.bodyObservations,
            orientationSweepResults: frameDiagnostics.orientationSweepResults
        )
    }

    private func saveForensicSequence(recoveryFrame: ForensicFrameSnapshot) {
        let capturedAt = Date()
        let directory = forensicDirectory(capturedAt: capturedAt)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var reports: [PostureForensicFrameReport] = []

            if let lastValidForensicFrame {
                reports.append(try saveForensicFrame(lastValidForensicFrame, role: "last-valid", directory: directory))
            }

            if let pendingForensicCollapse {
                reports.append(try saveForensicFrame(pendingForensicCollapse, role: "collapsed", directory: directory))
            }

            reports.append(try saveForensicFrame(recoveryFrame, role: "recovered", directory: directory))

            let report = PostureForensicSequenceReport(
                capturedAt: capturedAt,
                trigger: "face-visible-collapsed-shoulders-then-recovered",
                directory: directory.path,
                baselineShoulderWidth: settings.baseline?.shoulderWidth,
                baselineNeckDistance: settings.baseline?.neckDistance,
                frames: reports
            )
            let reportURL = directory.appendingPathComponent("sequence.json")
            try Self.writeJSON(report, to: reportURL)
            runtimeDefaults.set(directory.path, forKey: RuntimeKeys.forensicLatestDirectory)
            runtimeDefaults.set(reportURL.path, forKey: RuntimeKeys.forensicLatestReport)
            runtimeDefaults.set(capturedAt, forKey: RuntimeKeys.forensicLatestCapturedAt)
        } catch {
            runtimeDefaults.set(error.localizedDescription, forKey: RuntimeKeys.forensicLastError)
        }
    }

    private func saveForensicFrame(
        _ snapshot: ForensicFrameSnapshot,
        role: String,
        directory: URL
    ) throws -> PostureForensicFrameReport {
        var imageFile: String?
        if let image = snapshot.image {
            let filename = "\(role).png"
            try Self.writePNG(image, to: directory.appendingPathComponent(filename))
            imageFile = filename
        }

        var rawFiles: [String] = []
        for plane in snapshot.rawPlanes {
            let filename = "\(role)-\(plane.name).raw"
            try plane.data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            rawFiles.append(filename)
        }

        return PostureForensicFrameReport(
            role: role,
            trackingFrame: snapshot.trackingFrame,
            pixelBuffer: snapshot.pixelBuffer,
            bodyObservations: snapshot.bodyObservations,
            orientationSweepResults: snapshot.orientationSweepResults,
            imageFile: imageFile,
            rawFiles: rawFiles
        )
    }

    private func forensicDirectory(capturedAt: Date) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let name = formatter.string(from: capturedAt)
            .replacingOccurrences(of: ":", with: "-")
        return root
            .appendingPathComponent("Sloucher", isDirectory: true)
            .appendingPathComponent("Forensics", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func publishFrameDiagnostics(
        _ diagnostics: PostureFrameDiagnostics,
        result: PostureAnalysisResult
    ) {
        runtimeDefaults.set(result.acceptedFrame, forKey: RuntimeKeys.frameAccepted)
        setRuntime(result.reason, forKey: RuntimeKeys.frameReason)
        runtimeDefaults.set(diagnostics.bodyObservationCount, forKey: RuntimeKeys.frameBodyObservationCount)
        runtimeDefaults.set(diagnostics.validBodyCandidateCount, forKey: RuntimeKeys.frameValidBodyCandidateCount)
        runtimeDefaults.set(diagnostics.faceDetected, forKey: RuntimeKeys.frameFaceDetected)
        runtimeDefaults.set(diagnostics.faceObservationCount, forKey: RuntimeKeys.frameFaceObservationCount)
        setRuntime(diagnostics.faceBox?.minX, forKey: RuntimeKeys.frameFaceBoxMinX)
        setRuntime(diagnostics.faceBox?.minY, forKey: RuntimeKeys.frameFaceBoxMinY)
        setRuntime(diagnostics.faceBox?.maxX, forKey: RuntimeKeys.frameFaceBoxMaxX)
        setRuntime(diagnostics.faceBox?.maxY, forKey: RuntimeKeys.frameFaceBoxMaxY)
        setRuntime(diagnostics.faceConfidence, forKey: RuntimeKeys.frameFaceConfidence)
        setRuntime(diagnostics.bodyFailureReason, forKey: RuntimeKeys.frameBodyFailure)
        setRuntime(diagnostics.headAnchorSource, forKey: RuntimeKeys.frameHeadAnchorSource)
        setRuntime(diagnostics.candidateConfidence, forKey: RuntimeKeys.frameCandidateConfidence)
        setRuntime(diagnostics.candidateShoulderWidth, forKey: RuntimeKeys.frameCandidateShoulderWidth)
        setRuntime(diagnostics.candidateNeckDistance, forKey: RuntimeKeys.frameCandidateNeckDistance)
        setRuntime(diagnostics.bestCandidateScore, forKey: RuntimeKeys.frameCandidateScore)
        setRuntime(diagnostics.rawNoseConfidence, forKey: RuntimeKeys.frameRawNoseConfidence)
        setRuntime(diagnostics.rawLeftEyeConfidence, forKey: RuntimeKeys.frameRawLeftEyeConfidence)
        setRuntime(diagnostics.rawRightEyeConfidence, forKey: RuntimeKeys.frameRawRightEyeConfidence)
        setRuntime(diagnostics.rawLeftShoulderConfidence, forKey: RuntimeKeys.frameRawLeftShoulderConfidence)
        setRuntime(diagnostics.rawRightShoulderConfidence, forKey: RuntimeKeys.frameRawRightShoulderConfidence)
        setRuntime(diagnostics.rawShoulderWidth, forKey: RuntimeKeys.frameRawShoulderWidth)
        setRuntime(diagnostics.rawRejectReason, forKey: RuntimeKeys.frameRawRejectReason)
        runtimeDefaults.set(diagnostics.forceInference, forKey: RuntimeKeys.frameForceInference)
        runtimeDefaults.set(diagnostics.motionGateSkipped, forKey: RuntimeKeys.frameMotionGateSkipped)
        setRuntime(diagnostics.motionGateMeanAbsoluteDifference, forKey: RuntimeKeys.frameMotionGateMAD)
        setRuntime(diagnostics.motionGateThreshold, forKey: RuntimeKeys.frameMotionGateThreshold)
        runtimeDefaults.set(diagnostics.motionGateHadPreviousFrame, forKey: RuntimeKeys.frameMotionGateHadPreviousFrame)
        setRuntime(diagnostics.motionGateFrameHash, forKey: RuntimeKeys.frameMotionGateFrameHash)
        runtimeDefaults.set(diagnostics.consecutiveFailureFrameCount, forKey: RuntimeKeys.frameConsecutiveFailureFrameCount)
        runtimeDefaults.set(
            diagnostics.forcedVisionAttemptsSinceFailure,
            forKey: RuntimeKeys.frameForcedVisionAttemptsSinceFailure
        )
        setRuntime(diagnostics.orientationRetryBestOrientation, forKey: RuntimeKeys.frameOrientationRetryBestOrientation)
        setRuntime(
            diagnostics.orientationRetryBestValidCandidateCount,
            forKey: RuntimeKeys.frameOrientationRetryBestValidCandidateCount
        )
        setRuntime(
            diagnostics.orientationRetryUpMirroredValidCandidateCount,
            forKey: RuntimeKeys.frameOrientationRetryUpMirroredValidCandidateCount
        )
        setRuntime(
            diagnostics.orientationRetryUpMirroredShoulderWidth,
            forKey: RuntimeKeys.frameOrientationRetryUpMirroredShoulderWidth
        )
        setRuntime(
            diagnostics.orientationRetryUpMirroredRejectReason,
            forKey: RuntimeKeys.frameOrientationRetryUpMirroredRejectReason
        )
    }

    private func publishPixelBufferDiagnostics(_ diagnostics: PosturePixelBufferDiagnostics?) {
        guard let diagnostics else {
            runtimeDefaults.removeObject(forKey: RuntimeKeys.framePixelFormat)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.framePixelFormatCode)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.framePixelWidth)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.framePixelHeight)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.framePixelIsPlanar)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.framePixelPlaneCount)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.framePixelPresentationTimeSeconds)
            return
        }

        runtimeDefaults.set(diagnostics.pixelFormat, forKey: RuntimeKeys.framePixelFormat)
        runtimeDefaults.set(Int(diagnostics.pixelFormatCode), forKey: RuntimeKeys.framePixelFormatCode)
        runtimeDefaults.set(diagnostics.width, forKey: RuntimeKeys.framePixelWidth)
        runtimeDefaults.set(diagnostics.height, forKey: RuntimeKeys.framePixelHeight)
        runtimeDefaults.set(diagnostics.isPlanar, forKey: RuntimeKeys.framePixelIsPlanar)
        runtimeDefaults.set(diagnostics.planeCount, forKey: RuntimeKeys.framePixelPlaneCount)
        setRuntime(diagnostics.presentationTimeSeconds, forKey: RuntimeKeys.framePixelPresentationTimeSeconds)
    }

    private func publishFrameIdentityDiagnostics(_ diagnostics: PostureFrameIdentityDiagnostics?) {
        guard let diagnostics else {
            runtimeDefaults.removeObject(forKey: RuntimeKeys.frameLumaSampleHash)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.frameLumaSampleChecksum)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.frameLumaSampleWidth)
            runtimeDefaults.removeObject(forKey: RuntimeKeys.frameLumaSampleHeight)
            return
        }

        runtimeDefaults.set(diagnostics.lumaSampleHash, forKey: RuntimeKeys.frameLumaSampleHash)
        runtimeDefaults.set(diagnostics.lumaSampleChecksum, forKey: RuntimeKeys.frameLumaSampleChecksum)
        runtimeDefaults.set(diagnostics.lumaSampleWidth, forKey: RuntimeKeys.frameLumaSampleWidth)
        runtimeDefaults.set(diagnostics.lumaSampleHeight, forKey: RuntimeKeys.frameLumaSampleHeight)
    }

    private func setRuntime(_ value: Any?, forKey key: String) {
        if let value {
            runtimeDefaults.set(value, forKey: key)
        } else {
            runtimeDefaults.removeObject(forKey: key)
        }
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(value) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func pixelBufferDiagnostics(from sampleBuffer: CMSampleBuffer) -> PosturePixelBufferDiagnostics? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let isPlanar = planeCount > 0
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if isPlanar {
            let planes = 0..<planeCount
            return PosturePixelBufferDiagnostics(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                pixelFormat: fourCC(format),
                pixelFormatCode: format,
                isPlanar: true,
                planeCount: planeCount,
                bytesPerRow: planes.map { CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, $0) },
                planeWidths: planes.map { CVPixelBufferGetWidthOfPlane(pixelBuffer, $0) },
                planeHeights: planes.map { CVPixelBufferGetHeightOfPlane(pixelBuffer, $0) },
                presentationTimeSeconds: presentationTime.isValid ? presentationTime.seconds : nil
            )
        }

        return PosturePixelBufferDiagnostics(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: fourCC(format),
            pixelFormatCode: format,
            isPlanar: false,
            planeCount: 0,
            bytesPerRow: [CVPixelBufferGetBytesPerRow(pixelBuffer)],
            planeWidths: [CVPixelBufferGetWidth(pixelBuffer)],
            planeHeights: [CVPixelBufferGetHeight(pixelBuffer)],
            presentationTimeSeconds: presentationTime.isValid ? presentationTime.seconds : nil
        )
    }

    private static func frameIdentityDiagnostics(from sampleBuffer: CMSampleBuffer) -> PostureFrameIdentityDiagnostics? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let sampleWidth = 64
        let sampleHeight = 36
        let samples: [UInt8]?

        if CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            samples = sampledPlanarLuma(
                from: pixelBuffer,
                sampleWidth: sampleWidth,
                sampleHeight: sampleHeight
            )
        } else {
            samples = sampledPackedLuma(
                from: pixelBuffer,
                sampleWidth: sampleWidth,
                sampleHeight: sampleHeight
            )
        }

        guard let samples, !samples.isEmpty else { return nil }

        return PostureFrameIdentityDiagnostics(
            lumaSampleHash: lumaHash(samples),
            lumaSampleChecksum: samples.reduce(0) { $0 + Int($1) },
            lumaSampleWidth: sampleWidth,
            lumaSampleHeight: sampleHeight
        )
    }

    private static func sampledPlanarLuma(
        from pixelBuffer: CVPixelBuffer,
        sampleWidth: Int,
        sampleHeight: Int
    ) -> [UInt8]? {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, bytesPerRow > 0 else {
            return nil
        }

        let base = baseAddress.assumingMemoryBound(to: UInt8.self)
        var samples: [UInt8] = []
        samples.reserveCapacity(sampleWidth * sampleHeight)

        for sampleY in 0..<sampleHeight {
            let sourceY = min(height - 1, sampleY * height / sampleHeight)
            let row = base.advanced(by: sourceY * bytesPerRow)

            for sampleX in 0..<sampleWidth {
                let sourceX = min(width - 1, sampleX * width / sampleWidth)
                samples.append(row[sourceX])
            }
        }

        return samples
    }

    private static func sampledPackedLuma(
        from pixelBuffer: CVPixelBuffer,
        sampleWidth: Int,
        sampleHeight: Int
    ) -> [UInt8]? {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else {
            return nil
        }

        switch pixelFormat {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB, kCVPixelFormatType_32RGBA:
            break
        default:
            return nil
        }

        let base = baseAddress.assumingMemoryBound(to: UInt8.self)
        var samples: [UInt8] = []
        samples.reserveCapacity(sampleWidth * sampleHeight)

        for sampleY in 0..<sampleHeight {
            let sourceY = min(height - 1, sampleY * height / sampleHeight)
            let row = base.advanced(by: sourceY * bytesPerRow)

            for sampleX in 0..<sampleWidth {
                let sourceX = min(width - 1, sampleX * width / sampleWidth)
                let pixel = row.advanced(by: sourceX * 4)
                samples.append(luma(fromPackedPixel: pixel, pixelFormat: pixelFormat))
            }
        }

        return samples
    }

    private static func luma(fromPackedPixel pixel: UnsafePointer<UInt8>, pixelFormat: OSType) -> UInt8 {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        switch pixelFormat {
        case kCVPixelFormatType_32ARGB:
            red = pixel[1]
            green = pixel[2]
            blue = pixel[3]
        case kCVPixelFormatType_32RGBA:
            red = pixel[0]
            green = pixel[1]
            blue = pixel[2]
        default:
            blue = pixel[0]
            green = pixel[1]
            red = pixel[2]
        }

        let weighted = UInt16(red) * 77 + UInt16(green) * 150 + UInt16(blue) * 29
        return UInt8(weighted >> 8)
    }

    private static func lumaHash(_ samples: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for sample in samples {
            hash ^= UInt64(sample)
            hash &*= 0x100000001b3
        }

        return String(format: "%016llx", CUnsignedLongLong(hash))
    }

    private static func rawPlaneDumps(from sampleBuffer: CMSampleBuffer) -> [RawPlaneDump] {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return [] }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount > 0 {
            return (0..<planeCount).compactMap { plane in
                guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                    return nil
                }

                let byteCount = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) *
                    CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                return RawPlaneDump(
                    name: "plane\(plane)",
                    data: Data(bytes: baseAddress, count: byteCount)
                )
            }
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        return [
            RawPlaneDump(
                name: "packed",
                data: Data(bytes: baseAddress, count: byteCount)
            )
        ]
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]

        let scalars = bytes.map { byte -> UnicodeScalar in
            if byte >= 32 && byte <= 126 {
                return UnicodeScalar(byte)
            }
            return "."
        }

        return String(String.UnicodeScalarView(scalars))
    }

    private static func trackingSummary(
        from frames: [PostureTrackingFrameDiagnostics]
    ) -> PostureTrackingSummaryDiagnostics {
        let shoulderWidths = frames
            .compactMap(\.rawShoulderWidth)
            .filter(\.isFinite)
            .sorted()
        let metricShoulderWidths = frames
            .compactMap(\.metricShoulderWidth)
            .filter(\.isFinite)
            .sorted()
        let rejectReasons = frames
            .filter { !$0.acceptedFrame }
            .compactMap { $0.rawRejectReason ?? $0.reason }
        let rejectReasonCounts = Dictionary(grouping: rejectReasons, by: { $0 })
            .mapValues(\.count)

        return PostureTrackingSummaryDiagnostics(
            frameCount: frames.count,
            acceptedFrameCount: frames.filter(\.acceptedFrame).count,
            faceDetectedFrameCount: frames.filter(\.faceDetected).count,
            bodyObservationFrameCount: frames.filter { $0.bodyObservationCount > 0 }.count,
            validCandidateFrameCount: frames.filter { $0.validBodyCandidateCount > 0 }.count,
            noBodyObservationFrameCount: frames.filter {
                !$0.acceptedFrame && $0.bodyObservationCount == 0
            }.count,
            invalidBodyCandidateFrameCount: frames.filter {
                !$0.acceptedFrame &&
                    $0.bodyObservationCount > 0 &&
                    $0.validBodyCandidateCount == 0
            }.count,
            motionSkippedFrameCount: frames.filter(\.motionGateSkipped).count,
            forcedInferenceFrameCount: frames.filter(\.forceInference).count,
            uniqueLumaHashCount: Set(frames.compactMap(\.lumaSampleHash)).count,
            latestPresentationTimeSeconds: frames.last?.presentationTimeSeconds,
            latestStatus: frames.last?.status,
            latestRejectReason: frames.last.flatMap {
                $0.acceptedFrame ? nil : ($0.rawRejectReason ?? $0.reason)
            },
            rawShoulderWidthMin: shoulderWidths.first,
            rawShoulderWidthMedian: median(shoulderWidths),
            rawShoulderWidthMax: shoulderWidths.last,
            metricShoulderWidthMin: metricShoulderWidths.first,
            metricShoulderWidthMedian: median(metricShoulderWidths),
            metricShoulderWidthMax: metricShoulderWidths.last,
            rejectReasonCounts: rejectReasonCounts
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }

        let midpoint = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[midpoint - 1] + values[midpoint]) / 2
        }

        return values[midpoint]
    }

    private static func bestOrientationName(in results: [PostureOrientationDiagnostics]) -> String? {
        results.max { first, second in
            orientationScore(first) < orientationScore(second)
        }?.orientation
    }

    private static func orientationScore(_ result: PostureOrientationDiagnostics) -> Double {
        let confidence = result.candidateConfidence ??
            result.leftShoulderConfidence ??
            result.rightShoulderConfidence ??
            result.noseConfidence ??
            0
        let shoulderWidth = result.shoulderWidth ?? 0

        return Double(result.validBodyCandidateCount) * 1000 +
            Double(result.bodyObservationCount) * 100 +
            confidence * 10 +
            shoulderWidth
    }

    private enum RuntimeKeys {
        static let didShowCalibrationHint = "runtime.didShowCalibrationHint"
        static let status = "runtime.status"
        static let statusDisplayName = "runtime.statusDisplayName"
        static let detail = "runtime.detail"
        static let hasBaseline = "runtime.hasBaseline"
        static let updatedAt = "runtime.updatedAt"
        static let baselineNeckDistance = "runtime.baseline.neckDistance"
        static let baselineShoulderWidth = "runtime.baseline.shoulderWidth"
        static let baselineFaceCenterY = "runtime.baseline.faceCenterY"
        static let baselineFaceWidth = "runtime.baseline.faceWidth"
        static let baselinePrimarySource = "runtime.baseline.primarySource"
        static let metricSource = "runtime.metric.source"
        static let metricNeckDistance = "runtime.metric.neckDistance"
        static let metricShoulderWidth = "runtime.metric.shoulderWidth"
        static let metricCloseness = "runtime.metric.closeness"
        static let metricFaceCenterY = "runtime.metric.faceCenterY"
        static let metricFaceWidth = "runtime.metric.faceWidth"
        static let metricConfidence = "runtime.metric.confidence"
        static let metricTimestamp = "runtime.metric.timestamp"
        static let calibrationBodySamples = "runtime.calibration.bodySamples"
        static let calibrationLastFailure = "runtime.calibration.lastFailure"
        static let calibrationFrames = "runtime.calibration.frames"
        static let calibrationBodySuccesses = "runtime.calibration.bodySuccesses"
        static let calibrationRejectedSamples = "runtime.calibration.rejectedSamples"
        static let calibrationLastRejectReason = "runtime.calibration.lastRejectReason"
        static let calibrationBodyObservationCount = "runtime.calibration.bodyObservationCount"
        static let calibrationValidBodyCandidateCount = "runtime.calibration.validBodyCandidateCount"
        static let calibrationFaceDetected = "runtime.calibration.faceDetected"
        static let calibrationLastBodyFailure = "runtime.calibration.lastBodyFailure"
        static let calibrationLastCandidateConfidence = "runtime.calibration.lastCandidate.confidence"
        static let calibrationLastCandidateShoulderWidth = "runtime.calibration.lastCandidate.shoulderWidth"
        static let calibrationLastCandidateNeckDistance = "runtime.calibration.lastCandidate.neckDistance"
        static let calibrationLastCandidateScore = "runtime.calibration.lastCandidate.score"
        static let calibrationHeadAnchorSource = "runtime.calibration.headAnchorSource"
        static let calibrationSeedCandidates = "runtime.calibration.seedCandidates"
        static let calibrationSeedAccepted = "runtime.calibration.seedAccepted"
        static let calibrationBodyObservationTotal = "runtime.calibration.bodyObservationTotal"
        static let calibrationValidBodyCandidateTotal = "runtime.calibration.validBodyCandidateTotal"
        static let calibrationFaceDetectedFrames = "runtime.calibration.faceDetectedFrames"
        static let calibrationLastAttemptPrefix = "runtime.calibration.lastAttempt"
        static let calibrationLastFailedPrefix = "runtime.calibration.lastFailed"
        static let calibrationLastSucceededPrefix = "runtime.calibration.lastSucceeded"
        static let calibrationDebugOrientationSweeps = "runtime.calibration.debug.orientationSweeps"
        static let calibrationDebugBestOrientation = "runtime.calibration.debug.bestOrientation"
        static let frameAccepted = "runtime.frame.accepted"
        static let frameReason = "runtime.frame.reason"
        static let frameBodyObservationCount = "runtime.frame.bodyObservationCount"
        static let frameValidBodyCandidateCount = "runtime.frame.validBodyCandidateCount"
        static let frameFaceDetected = "runtime.frame.faceDetected"
        static let frameFaceObservationCount = "runtime.frame.faceObservationCount"
        static let frameFaceBoxMinX = "runtime.frame.face.bbox.minX"
        static let frameFaceBoxMinY = "runtime.frame.face.bbox.minY"
        static let frameFaceBoxMaxX = "runtime.frame.face.bbox.maxX"
        static let frameFaceBoxMaxY = "runtime.frame.face.bbox.maxY"
        static let frameFaceConfidence = "runtime.frame.face.confidence"
        static let frameBodyFailure = "runtime.frame.bodyFailure"
        static let frameHeadAnchorSource = "runtime.frame.headAnchorSource"
        static let frameCandidateConfidence = "runtime.frame.candidate.confidence"
        static let frameCandidateShoulderWidth = "runtime.frame.candidate.shoulderWidth"
        static let frameCandidateNeckDistance = "runtime.frame.candidate.neckDistance"
        static let frameCandidateScore = "runtime.frame.candidate.score"
        static let frameRawNoseConfidence = "runtime.frame.raw.nose.confidence"
        static let frameRawLeftEyeConfidence = "runtime.frame.raw.leftEye.confidence"
        static let frameRawRightEyeConfidence = "runtime.frame.raw.rightEye.confidence"
        static let frameRawLeftShoulderConfidence = "runtime.frame.raw.leftShoulder.confidence"
        static let frameRawRightShoulderConfidence = "runtime.frame.raw.rightShoulder.confidence"
        static let frameRawShoulderWidth = "runtime.frame.raw.shoulderWidth"
        static let frameRawRejectReason = "runtime.frame.raw.rejectReason"
        static let frameForceInference = "runtime.frame.forceInference"
        static let frameMotionGateSkipped = "runtime.frame.motionGate.skipped"
        static let frameMotionGateMAD = "runtime.frame.motionGate.thumbnailMAD"
        static let frameMotionGateThreshold = "runtime.frame.motionGate.threshold"
        static let frameMotionGateHadPreviousFrame = "runtime.frame.motionGate.hadPreviousFrame"
        static let frameMotionGateFrameHash = "runtime.frame.motionGate.frameHash"
        static let frameConsecutiveFailureFrameCount = "runtime.frame.failureRun.consecutiveFrames"
        static let frameForcedVisionAttemptsSinceFailure = "runtime.frame.failureRun.forcedVisionAttempts"
        static let frameOrientationRetryBestOrientation = "runtime.frame.orientationRetry.bestOrientation"
        static let frameOrientationRetryBestValidCandidateCount = "runtime.frame.orientationRetry.bestValidCandidateCount"
        static let frameOrientationRetryUpMirroredValidCandidateCount =
            "runtime.frame.orientationRetry.upMirrored.validCandidateCount"
        static let frameOrientationRetryUpMirroredShoulderWidth =
            "runtime.frame.orientationRetry.upMirrored.shoulderWidth"
        static let frameOrientationRetryUpMirroredRejectReason =
            "runtime.frame.orientationRetry.upMirrored.rejectReason"
        static let framePixelFormat = "runtime.frame.pixel.format"
        static let framePixelFormatCode = "runtime.frame.pixel.formatCode"
        static let framePixelWidth = "runtime.frame.pixel.width"
        static let framePixelHeight = "runtime.frame.pixel.height"
        static let framePixelIsPlanar = "runtime.frame.pixel.isPlanar"
        static let framePixelPlaneCount = "runtime.frame.pixel.planeCount"
        static let framePixelPresentationTimeSeconds = "runtime.frame.pixel.presentationTimeSeconds"
        static let frameLumaSampleHash = "runtime.frame.lumaSample.hash"
        static let frameLumaSampleChecksum = "runtime.frame.lumaSample.checksum"
        static let frameLumaSampleWidth = "runtime.frame.lumaSample.width"
        static let frameLumaSampleHeight = "runtime.frame.lumaSample.height"
        static let trackingDebugFrames = "runtime.tracking.debug.frames"
        static let trackingDebugSummary = "runtime.tracking.debug.summary"
        static let trackingDebugOrientationSweeps = "runtime.tracking.debug.orientationSweeps"
        static let trackingDebugBestOrientation = "runtime.tracking.debug.bestOrientation"
        static let trackingDebugWindowFrames = "runtime.tracking.debug.window.frames"
        static let trackingDebugAcceptedFrames = "runtime.tracking.debug.window.acceptedFrames"
        static let trackingDebugFaceDetectedFrames = "runtime.tracking.debug.window.faceDetectedFrames"
        static let trackingDebugBodyObservationFrames = "runtime.tracking.debug.window.bodyObservationFrames"
        static let trackingDebugValidCandidateFrames = "runtime.tracking.debug.window.validCandidateFrames"
        static let trackingDebugNoBodyObservationFrames = "runtime.tracking.debug.window.noBodyObservationFrames"
        static let trackingDebugInvalidCandidateFrames = "runtime.tracking.debug.window.invalidCandidateFrames"
        static let trackingDebugMotionSkippedFrames = "runtime.tracking.debug.window.motionSkippedFrames"
        static let trackingDebugForcedInferenceFrames = "runtime.tracking.debug.window.forcedInferenceFrames"
        static let trackingDebugUniqueLumaHashes = "runtime.tracking.debug.window.uniqueLumaHashes"
        static let trackingDebugLatestPresentationTimeSeconds =
            "runtime.tracking.debug.latestPresentationTimeSeconds"
        static let trackingDebugLatestStatus = "runtime.tracking.debug.latestStatus"
        static let trackingDebugLatestRejectReason = "runtime.tracking.debug.latestRejectReason"
        static let trackingDebugRawShoulderWidthMin = "runtime.tracking.debug.rawShoulderWidth.min"
        static let trackingDebugRawShoulderWidthMedian = "runtime.tracking.debug.rawShoulderWidth.median"
        static let trackingDebugRawShoulderWidthMax = "runtime.tracking.debug.rawShoulderWidth.max"
        static let trackingDebugMetricShoulderWidthMin = "runtime.tracking.debug.metricShoulderWidth.min"
        static let trackingDebugMetricShoulderWidthMedian = "runtime.tracking.debug.metricShoulderWidth.median"
        static let trackingDebugMetricShoulderWidthMax = "runtime.tracking.debug.metricShoulderWidth.max"
        static let forensicLatestDirectory = "runtime.forensics.latestDirectory"
        static let forensicLatestReport = "runtime.forensics.latestReport"
        static let forensicLatestCapturedAt = "runtime.forensics.latestCapturedAt"
        static let forensicLastError = "runtime.forensics.lastError"
    }
}
