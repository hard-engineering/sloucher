import Foundation

final class SettingsStore: ObservableObject {
    @Published var sensitivity: Sensitivity {
        didSet { defaults.set(sensitivity.rawValue, forKey: Keys.sensitivity) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    @Published var overlayEnabled: Bool {
        didSet { defaults.set(overlayEnabled, forKey: Keys.overlayEnabled) }
    }

    // On-failure padding rescue. Default on: it only runs when full-frame body
    // pose fails, so enabling it cannot regress frames that already work. Exposed
    // as a flag so it can be disabled without a rebuild if the live probe shows
    // a problem.
    @Published var paddingRescueEnabled: Bool {
        didSet { defaults.set(paddingRescueEnabled, forKey: Keys.paddingRescueEnabled) }
    }

    @Published var baseline: PostureBaseline? {
        didSet { persistBaseline() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawSensitivity = defaults.object(forKey: Keys.sensitivity) as? Int ?? Sensitivity.normal.rawValue
        self.sensitivity = Sensitivity(rawValue: rawSensitivity) ?? .normal
        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        self.overlayEnabled = defaults.object(forKey: Keys.overlayEnabled) as? Bool ?? true
        self.paddingRescueEnabled = defaults.object(forKey: Keys.paddingRescueEnabled) as? Bool ?? true
        self.baseline = Self.loadBaseline(from: defaults)
        if self.baseline == nil {
            Self.clearPersistedBaseline(from: defaults)
        }
    }

    var decisionConfig: PostureDecisionConfig {
        .from(sensitivity: sensitivity, paddingRescueEnabled: paddingRescueEnabled)
    }

    func clearBaseline() {
        baseline = nil
    }

    private func persistBaseline() {
        guard let baseline else {
            defaults.removeObject(forKey: Keys.baselineNeckDistance)
            defaults.removeObject(forKey: Keys.baselineShoulderWidth)
            defaults.removeObject(forKey: Keys.baselineFaceCenterY)
            defaults.removeObject(forKey: Keys.baselineFaceWidth)
            defaults.removeObject(forKey: Keys.baselineCalibratedAt)
            defaults.removeObject(forKey: Keys.baselinePrimarySource)
            return
        }

        defaults.set(baseline.neckDistance, forKey: Keys.baselineNeckDistance)
        defaults.set(baseline.shoulderWidth, forKey: Keys.baselineShoulderWidth)
        defaults.set(baseline.faceCenterY, forKey: Keys.baselineFaceCenterY)
        defaults.set(baseline.faceWidth, forKey: Keys.baselineFaceWidth)
        defaults.set(baseline.calibratedAt, forKey: Keys.baselineCalibratedAt)
        defaults.set(baseline.primarySource.rawValue, forKey: Keys.baselinePrimarySource)
    }

    private static func loadBaseline(from defaults: UserDefaults) -> PostureBaseline? {
        guard
            defaults.object(forKey: Keys.baselineNeckDistance) != nil,
            defaults.object(forKey: Keys.baselineShoulderWidth) != nil
        else {
            return nil
        }

        let rawSource = defaults.string(forKey: Keys.baselinePrimarySource)
        let primarySource = rawSource.flatMap(PostureMetricSource.init(rawValue:)) ?? .body
        let faceCenterY = defaults.object(forKey: Keys.baselineFaceCenterY) as? Double
        let faceWidth = defaults.object(forKey: Keys.baselineFaceWidth) as? Double

        let baseline = PostureBaseline(
            neckDistance: defaults.double(forKey: Keys.baselineNeckDistance),
            shoulderWidth: defaults.double(forKey: Keys.baselineShoulderWidth),
            faceCenterY: faceCenterY,
            faceWidth: faceWidth,
            calibratedAt: defaults.object(forKey: Keys.baselineCalibratedAt) as? Date ?? .distantPast,
            primarySource: primarySource
        )

        return baseline.isUsable ? baseline : nil
    }

    private static func clearPersistedBaseline(from defaults: UserDefaults) {
        defaults.removeObject(forKey: Keys.baselineNeckDistance)
        defaults.removeObject(forKey: Keys.baselineShoulderWidth)
        defaults.removeObject(forKey: Keys.baselineFaceCenterY)
        defaults.removeObject(forKey: Keys.baselineFaceWidth)
        defaults.removeObject(forKey: Keys.baselineCalibratedAt)
        defaults.removeObject(forKey: Keys.baselinePrimarySource)
    }

    private enum Keys {
        static let sensitivity = "sensitivity"
        static let notificationsEnabled = "notificationsEnabled"
        static let soundEnabled = "soundEnabled"
        static let overlayEnabled = "overlayEnabled"
        static let paddingRescueEnabled = "paddingRescueEnabled"
        static let baselineNeckDistance = "baseline.neckDistance"
        static let baselineShoulderWidth = "baseline.shoulderWidth"
        static let baselineFaceCenterY = "baseline.faceCenterY"
        static let baselineFaceWidth = "baseline.faceWidth"
        static let baselineCalibratedAt = "baseline.calibratedAt"
        static let baselinePrimarySource = "baseline.primarySource"
    }
}
