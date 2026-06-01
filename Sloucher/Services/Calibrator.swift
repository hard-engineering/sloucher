import Foundation

final class Calibrator {
    private(set) var isCollecting = false
    var bodySampleCount: Int {
        samples.count
    }
    var requiredSampleCount: Int {
        minimumSamples
    }
    var latestSample: PostureMetrics? {
        samples.last
    }
    private(set) var rejectedSampleCount = 0
    private(set) var lastRejectReason: String?

    private var samples: [PostureMetrics] = []
    private var attemptStartedAt: Date?
    private var collectionStartedAt: Date?
    private var duration: TimeInterval = 2
    private var minimumSamples = 8

    func start(
        duration: TimeInterval,
        minimumSamples: Int
    ) {
        self.duration = max(0, duration)
        self.minimumSamples = max(1, minimumSamples)
        rejectedSampleCount = 0
        lastRejectReason = nil
        // Recalibration must collect live body-pose samples from the current
        // camera view; seeded samples can hide startup Vision failures.
        samples = []
        attemptStartedAt = Date()
        collectionStartedAt = nil
        isCollecting = true
    }

    func cancel() {
        samples = []
        attemptStartedAt = nil
        collectionStartedAt = nil
        isCollecting = false
    }

    func hasTimedOut(
        collectionTimeout: TimeInterval,
        noSampleTimeout: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard isCollecting, let attemptStartedAt else { return false }

        if samples.isEmpty {
            return now.timeIntervalSince(attemptStartedAt) >= noSampleTimeout
        }

        // Calibration should not burn the full collection timeout before Vision
        // has produced the first usable shoulder sample; cold starts can return
        // many camera frames before body pose is usable.
        guard let collectionStartedAt else { return false }
        return now.timeIntervalSince(collectionStartedAt) >= collectionTimeout
    }

    func add(metrics: PostureMetrics) -> PostureBaseline? {
        guard isCollecting else {
            rejectedSampleCount += 1
            lastRejectReason = "Calibration is not collecting."
            return nil
        }

        if let rejectionReason = rejectionReason(for: metrics) {
            rejectedSampleCount += 1
            lastRejectReason = rejectionReason
            return nil
        }

        samples.append(metrics)
        // Start the timed calibration window at the first accepted body sample,
        // not at button click, so startup/Vision warm-up frames do not count as
        // failed posture samples.
        if collectionStartedAt == nil {
            collectionStartedAt = metrics.timestamp
        }
        lastRejectReason = nil
        return finishIfReady(now: metrics.timestamp)
    }

    func finishIfReady(now: Date = Date()) -> PostureBaseline? {
        guard
            isCollecting,
            let collectionStartedAt,
            now.timeIntervalSince(collectionStartedAt) >= duration,
            samples.count >= minimumSamples
        else {
            return nil
        }

        isCollecting = false

        return makeBaseline()
    }

    private func rejectionReason(for metrics: PostureMetrics) -> String? {
        guard metrics.source == .body else {
            return "Only body pose can calibrate posture."
        }

        guard metrics.neckDistance.isFinite, metrics.neckDistance > 0 else {
            return "Head-to-shoulder distance was invalid."
        }

        guard metrics.shoulderWidth.isFinite, metrics.shoulderWidth >= 0.12 else {
            return "Shoulder width was too small: \(metrics.shoulderWidth.formatted(.number.precision(.fractionLength(3))))."
        }

        guard metrics.confidence >= 0.3 else {
            return "Pose confidence was too low: \(Double(metrics.confidence).formatted(.number.precision(.fractionLength(2))))."
        }

        return nil
    }

    private func makeBaseline() -> PostureBaseline {
        PostureBaseline(
            neckDistance: median(samples.map(\.neckDistance)),
            shoulderWidth: median(samples.map(\.shoulderWidth)),
            faceCenterY: medianOptional(samples.compactMap(\.faceCenterY)) ?? median(samples.map(\.neckDistance)),
            faceWidth: medianOptional(samples.compactMap(\.faceWidth)) ?? median(samples.map(\.shoulderWidth)),
            calibratedAt: Date(),
            primarySource: .body
        )
    }

    private func medianOptional(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return median(values)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2

        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }

        return sorted[middle]
    }
}
