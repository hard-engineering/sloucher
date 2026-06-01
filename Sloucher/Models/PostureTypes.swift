import CoreGraphics
import Foundation

enum PostureStatus: String, CaseIterable {
    case uncalibrated
    case good
    case slouching
    case paused
    case snoozed
    case calibrating
    case cannotSee
    case cameraDenied
    case cameraUnavailable

    var displayName: String {
        switch self {
        case .uncalibrated: "Needs calibration"
        case .good: "Good"
        case .slouching: "Slouching"
        case .paused: "Paused"
        case .snoozed: "Snoozed"
        case .calibrating: "Calibrating"
        case .cannotSee: "Posture not measurable"
        case .cameraDenied: "Camera denied"
        case .cameraUnavailable: "No camera"
        }
    }

    var menuBarSystemImage: String {
        switch self {
        case .good: "checkmark.circle"
        case .slouching: "exclamationmark.triangle"
        case .paused, .snoozed: "pause.circle"
        case .calibrating: "camera.metering.center.weighted"
        case .cannotSee: "viewfinder"
        case .cameraDenied, .cameraUnavailable: "video.slash"
        case .uncalibrated: "figure.stand"
        }
    }
}

enum Sensitivity: Int, CaseIterable, Identifiable {
    case strict = 0
    case normal = 1
    case relaxed = 2

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .strict: "Strict"
        case .normal: "Normal"
        case .relaxed: "Relaxed"
        }
    }

    var dropThreshold: Double {
        switch self {
        case .strict: 0.06
        case .normal: 0.10
        case .relaxed: 0.14
        }
    }
}

enum PostureMetricSource: String, Codable {
    case body
    case face

    var displayName: String {
        switch self {
        case .body: "body"
        case .face: "face"
        }
    }
}

struct PostureBaseline: Codable, Equatable {
    let neckDistance: Double
    let shoulderWidth: Double
    let faceCenterY: Double?
    let faceWidth: Double?
    let calibratedAt: Date
    let primarySource: PostureMetricSource

    var isUsable: Bool {
        hasBodyBaseline || hasFaceBaseline
    }

    var hasBodyBaseline: Bool {
        primarySource == .body &&
            neckDistance.isFinite && neckDistance > 0 && neckDistance < 4 &&
            shoulderWidth.isFinite && shoulderWidth >= 0.12
    }

    var hasFaceBaseline: Bool {
        guard let faceCenterY, let faceWidth else { return false }
        return faceCenterY.isFinite && faceCenterY > 0 &&
            faceWidth.isFinite && faceWidth > 0
    }

    init(
        neckDistance: Double,
        shoulderWidth: Double,
        faceCenterY: Double? = nil,
        faceWidth: Double? = nil,
        calibratedAt: Date,
        primarySource: PostureMetricSource = .body
    ) {
        self.neckDistance = neckDistance
        self.shoulderWidth = shoulderWidth
        self.faceCenterY = faceCenterY
        self.faceWidth = faceWidth
        self.calibratedAt = calibratedAt
        self.primarySource = primarySource
    }
}

struct PostureMetrics: Equatable {
    let source: PostureMetricSource
    let neckDistance: Double
    let shoulderWidth: Double
    let closeness: Double
    let shoulderTiltDegrees: Double
    let faceCenterY: Double?
    let faceWidth: Double?
    let confidence: Float
    let timestamp: Date

    var summary: String {
        "\(source.displayName) \(neckDistance.formatted(.number.precision(.fractionLength(2))))  close \(closeness.formatted(.number.precision(.fractionLength(2))))"
    }
}

struct PoseFrame: Equatable {
    let source: PostureMetricSource
    let nose: CGPoint?
    let leftEye: CGPoint?
    let rightEye: CGPoint?
    let leftShoulder: CGPoint?
    let rightShoulder: CGPoint?
    let faceCenter: CGPoint?
    let faceSize: CGSize?
    let confidence: Float
    let timestamp: Date

    var shoulderMidY: Double? {
        guard let leftShoulder, let rightShoulder else { return nil }
        return Double((leftShoulder.y + rightShoulder.y) / 2)
    }

    var shoulderWidth: Double? {
        guard let leftShoulder, let rightShoulder else { return nil }
        let dx = leftShoulder.x - rightShoulder.x
        let dy = leftShoulder.y - rightShoulder.y
        return sqrt(Double(dx * dx + dy * dy))
    }
}

struct MetricHistorySample: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let neckDistance: Double
    let wasSlouching: Bool
}

struct PostureFrameDiagnostics: Equatable {
    var bodyObservationCount: Int = 0
    var validBodyCandidateCount: Int = 0
    var faceDetected: Bool = false
    var bodyFailureReason: String?
    var headAnchorSource: String?
    var bestCandidateScore: Double?
    var candidateConfidence: Double?
    var candidateShoulderWidth: Double?
    var candidateNeckDistance: Double?
    var rawNoseConfidence: Double?
    var rawLeftEyeConfidence: Double?
    var rawRightEyeConfidence: Double?
    var rawLeftShoulderConfidence: Double?
    var rawRightShoulderConfidence: Double?
    var rawShoulderWidth: Double?
    var rawRejectReason: String?
    var bodyObservations: [PostureBodyObservationDiagnostics] = []
    var orientationSweepResults: [PostureOrientationDiagnostics] = []

    static let empty = PostureFrameDiagnostics()
}

struct PostureJointDiagnostics: Codable, Equatable {
    let x: Double
    let y: Double
    let confidence: Double
}

struct PostureBodyObservationDiagnostics: Codable, Equatable {
    let validCandidate: Bool
    let rejectReason: String?
    let shoulderWidth: Double?
    let neckDistance: Double?
    let candidateConfidence: Double?
    let joints: [String: PostureJointDiagnostics]
}

struct PostureOrientationDiagnostics: Codable, Equatable {
    let orientation: String
    let bodyObservationCount: Int
    let validBodyCandidateCount: Int
    let noseConfidence: Double?
    let leftEyeConfidence: Double?
    let rightEyeConfidence: Double?
    let leftShoulderConfidence: Double?
    let rightShoulderConfidence: Double?
    let shoulderWidth: Double?
    let neckDistance: Double?
    let candidateConfidence: Double?
    let rejectReason: String?
    let observations: [PostureBodyObservationDiagnostics]
}

struct PostureOrientationSweepDiagnostics: Codable, Equatable {
    let frame: Int
    let timestamp: Date
    let results: [PostureOrientationDiagnostics]
    let bestOrientation: String?
}

struct PostureTrackingFrameDiagnostics: Codable, Equatable {
    let frame: Int
    let timestamp: Date
    let status: String
    let acceptedFrame: Bool
    let reason: String?
    let bodyObservationCount: Int
    let validBodyCandidateCount: Int
    let faceDetected: Bool
    let candidateConfidence: Double?
    let candidateShoulderWidth: Double?
    let candidateNeckDistance: Double?
    let rawNoseConfidence: Double?
    let rawLeftShoulderConfidence: Double?
    let rawRightShoulderConfidence: Double?
    let rawShoulderWidth: Double?
    let rawRejectReason: String?
    let metricShoulderWidth: Double?
    let metricNeckDistance: Double?
    let metricCloseness: Double?
}

struct PostureTrackingSummaryDiagnostics: Codable, Equatable {
    let frameCount: Int
    let acceptedFrameCount: Int
    let faceDetectedFrameCount: Int
    let bodyObservationFrameCount: Int
    let validCandidateFrameCount: Int
    let noBodyObservationFrameCount: Int
    let invalidBodyCandidateFrameCount: Int
    let latestStatus: String?
    let latestRejectReason: String?
    let rawShoulderWidthMin: Double?
    let rawShoulderWidthMedian: Double?
    let rawShoulderWidthMax: Double?
    let metricShoulderWidthMin: Double?
    let metricShoulderWidthMedian: Double?
    let metricShoulderWidthMax: Double?
    let rejectReasonCounts: [String: Int]
}

struct PosturePixelBufferDiagnostics: Codable, Equatable {
    let width: Int
    let height: Int
    let pixelFormat: String
    let pixelFormatCode: UInt32
    let isPlanar: Bool
    let planeCount: Int
    let bytesPerRow: [Int]
    let planeWidths: [Int]
    let planeHeights: [Int]
    let presentationTimeSeconds: Double?
}

struct PostureForensicFrameReport: Codable, Equatable {
    let role: String
    let trackingFrame: PostureTrackingFrameDiagnostics
    let pixelBuffer: PosturePixelBufferDiagnostics
    let bodyObservations: [PostureBodyObservationDiagnostics]
    let orientationSweepResults: [PostureOrientationDiagnostics]
    let imageFile: String?
    let rawFiles: [String]
}

struct PostureForensicSequenceReport: Codable, Equatable {
    let capturedAt: Date
    let trigger: String
    let directory: String
    let baselineShoulderWidth: Double?
    let baselineNeckDistance: Double?
    let frames: [PostureForensicFrameReport]
}

struct PostureDecisionConfig: Equatable {
    let dropThreshold: Double
    let closenessThreshold: Double
    let holdSeconds: TimeInterval
    let recoverSeconds: TimeInterval
    let unreliableSeconds: TimeInterval

    static func from(sensitivity: Sensitivity) -> PostureDecisionConfig {
        return PostureDecisionConfig(
            dropThreshold: sensitivity.dropThreshold,
            closenessThreshold: 1.18,
            holdSeconds: 5,
            recoverSeconds: 3,
            unreliableSeconds: 8
        )
    }
}

struct PostureAnalysisResult {
    let status: PostureStatus
    let metrics: PostureMetrics?
    let pose: PoseFrame?
    let acceptedFrame: Bool
    let reason: String?
}
