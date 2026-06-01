import AVFoundation
import Foundation
import Vision

final class PostureAnalyzer {
    var baseline: PostureBaseline? {
        didSet {
            guard baseline != oldValue else { return }
            resetDecisionState()
        }
    }
    private(set) var lastFrameDiagnostics: PostureFrameDiagnostics = .empty

    private let motionGate = FrameMotionGate()
    private let minimumJointConfidence: VNConfidence = 0.22
    private let calibrationOrientationSweepLimit = 3
    private let trackingOrientationSweepLimit = 5

    private var currentStatus: PostureStatus = .good
    private var slouchCandidateSince: Date?
    private var recoveryCandidateSince: Date?
    private var unreliableSince: Date?
    private var lastReliableMetrics: PostureMetrics?
    private var lastReliablePose: PoseFrame?
    private var calibrationOrientationSweepCount = 0
    private var trackingOrientationSweepCount = 0

    private enum OrientationSweepMode {
        case calibration
        case tracking
    }

    private enum MetricExtractionResult {
        case success(PostureMetrics, PoseFrame?)
        case failure(String, PoseFrame?)
    }

    private struct BodyCandidate {
        let metrics: PostureMetrics
        let pose: PoseFrame
        let score: Double
        let headAnchorSource: String
    }

    private struct RawBodyProbe {
        let noseConfidence: Double?
        let leftEyeConfidence: Double?
        let rightEyeConfidence: Double?
        let leftShoulderConfidence: Double?
        let rightShoulderConfidence: Double?
        let shoulderWidth: Double?
        let neckDistance: Double?
        let candidateConfidence: Double?
        let rejectReason: String?

        var score: Double {
            if let candidateConfidence {
                return candidateConfidence + 1
            }

            let confidences = [
                noseConfidence,
                leftShoulderConfidence,
                rightShoulderConfidence
            ].compactMap(\.self)

            guard !confidences.isEmpty else { return 0 }
            return confidences.reduce(0, +) / Double(confidences.count)
        }
    }

    private struct FaceSignal {
        let centerX: Double
        let centerY: Double
        let width: Double
        let height: Double
        let confidence: Float
    }

    func analyze(
        sampleBuffer: CMSampleBuffer,
        config: PostureDecisionConfig,
        forceInference: Bool = false,
        collectCalibrationDiagnostics: Bool = false,
        collectTrackingDiagnostics: Bool = false
    ) -> PostureAnalysisResult {
        let now = Date()
        lastFrameDiagnostics = .empty
        let shouldForceInference = forceInference || unreliableSince != nil || currentStatus == .cannotSee

        guard motionGate.shouldRunInference(sampleBuffer: sampleBuffer, forceInference: shouldForceInference) else {
            lastFrameDiagnostics.bodyFailureReason = "Motion gate skipped inference."
            return handleMotionSkippedFrame(config: config, now: now)
        }

        switch extractMetrics(
            from: sampleBuffer,
            now: now,
            collectCalibrationDiagnostics: collectCalibrationDiagnostics,
            collectTrackingDiagnostics: collectTrackingDiagnostics
        ) {
        case .success(let metrics, let pose):
            unreliableSince = nil
            lastReliableMetrics = metrics
            lastReliablePose = pose
            let status = decideStatus(for: metrics, config: config, now: now)

            return PostureAnalysisResult(
                status: status,
                metrics: metrics,
                pose: pose,
                acceptedFrame: true,
                reason: nil
            )

        case .failure(let reason, let pose):
            return handleUnreliableFrame(reason: reason, pose: pose, config: config, now: now)
        }
    }

    func resetCalibrationDebugDiagnostics() {
        calibrationOrientationSweepCount = 0
    }

    func resetTrackingDebugDiagnostics() {
        trackingOrientationSweepCount = 0
    }

    private func extractMetrics(
        from sampleBuffer: CMSampleBuffer,
        now: Date,
        collectCalibrationDiagnostics: Bool,
        collectTrackingDiagnostics: Bool
    ) -> MetricExtractionResult {
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let faceLandmarksRequest = VNDetectFaceLandmarksRequest()
        // The capture output is intentionally unmirrored; preview mirroring is UI-only.
        // Passing .up keeps Vision's coordinates tied to the native camera buffer.
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([bodyRequest, faceRequest, faceLandmarksRequest])
        } catch {
            return .failure("Vision failed: \(error.localizedDescription)", nil)
        }

        let faceSignal = bestFaceSignal(
            rectanglesRequest: faceRequest,
            landmarksRequest: faceLandmarksRequest
        )
        lastFrameDiagnostics.faceDetected = faceSignal != nil
        let facePose = faceSignal.map { makeFacePose(from: $0, now: now) }

        switch makeBodyMetrics(from: bodyRequest, faceSignal: faceSignal, now: now) {
        case .success(let metrics, let pose):
            return .success(metrics, pose)
        case .failure(let bodyReason, _):
            if collectCalibrationDiagnostics, faceSignal != nil {
                collectOrientationSweepIfNeeded(from: sampleBuffer, mode: .calibration)
            } else if collectTrackingDiagnostics, faceSignal != nil {
                collectOrientationSweepIfNeeded(from: sampleBuffer, mode: .tracking)
            }

            return .failure(bodyReason, facePose)
        }
    }

    private func makeBodyMetrics(
        from request: VNDetectHumanBodyPoseRequest,
        faceSignal: FaceSignal?,
        now: Date
    ) -> MetricExtractionResult {
        guard let observations = request.results, !observations.isEmpty else {
            lastFrameDiagnostics.bodyObservationCount = 0
            lastFrameDiagnostics.validBodyCandidateCount = 0
            lastFrameDiagnostics.bodyFailureReason = "Looking for head and shoulders."
            return .failure("Looking for head and shoulders.", faceSignal.map { makeFacePose(from: $0, now: now) })
        }

        var candidates: [BodyCandidate] = []
        var lastFailureReason = "Need head and both shoulders in frame."
        lastFrameDiagnostics.bodyObservationCount = observations.count

        for observation in observations {
            do {
                let points = try observation.recognizedPoints(.all)
                switch makeBodyCandidate(from: points, faceSignal: faceSignal, now: now) {
                case .success(let metrics, let pose):
                    recordRawBodyProbe(rawBodyProbe(from: points, rejectReason: nil))
                    lastFrameDiagnostics.bodyObservations.append(
                        bodyObservationDiagnostics(from: points, validCandidate: true, rejectReason: nil)
                    )
                    let pose = pose ?? makePosePlaceholder(metrics: metrics, now: now)
                    candidates.append(
                        BodyCandidate(
                            metrics: metrics,
                            pose: pose,
                            score: bodyScore(metrics: metrics, pose: pose, faceSignal: faceSignal),
                            headAnchorSource: pose.nose == pose.faceCenter ? "face" : "body"
                        )
                    )
                case .failure(let reason, _):
                    recordRawBodyProbe(rawBodyProbe(from: points, rejectReason: reason))
                    lastFrameDiagnostics.bodyObservations.append(
                        bodyObservationDiagnostics(from: points, validCandidate: false, rejectReason: reason)
                    )
                    lastFailureReason = reason
                }
            } catch {
                lastFrameDiagnostics.bodyObservations.append(
                    PostureBodyObservationDiagnostics(
                        validCandidate: false,
                        rejectReason: "Vision joints unavailable.",
                        shoulderWidth: nil,
                        neckDistance: nil,
                        candidateConfidence: nil,
                        joints: [:]
                    )
                )
                lastFailureReason = "Vision joints unavailable."
            }
        }

        lastFrameDiagnostics.validBodyCandidateCount = candidates.count

        guard let bestCandidate = candidates.max(by: { $0.score < $1.score }) else {
            lastFrameDiagnostics.bodyFailureReason = lastFailureReason
            return .failure(lastFailureReason, faceSignal.map { makeFacePose(from: $0, now: now) })
        }

        lastFrameDiagnostics.bodyFailureReason = nil
        lastFrameDiagnostics.headAnchorSource = bestCandidate.headAnchorSource
        lastFrameDiagnostics.bestCandidateScore = bestCandidate.score
        lastFrameDiagnostics.candidateConfidence = Double(bestCandidate.metrics.confidence)
        lastFrameDiagnostics.candidateShoulderWidth = bestCandidate.metrics.shoulderWidth
        lastFrameDiagnostics.candidateNeckDistance = bestCandidate.metrics.neckDistance

        return .success(bestCandidate.metrics, bestCandidate.pose)
    }

    private func makeBodyCandidate(
        from points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        faceSignal: FaceSignal?,
        now: Date
    ) -> MetricExtractionResult {
        let nose = reliablePoint(.nose, in: points)
        guard let leftShoulder = reliablePoint(.leftShoulder, in: points) else {
            return .failure("Need left shoulder in frame.", nil)
        }
        guard let rightShoulder = reliablePoint(.rightShoulder, in: points) else {
            return .failure("Need right shoulder in frame.", nil)
        }
        guard nose != nil || faceSignal != nil else {
            return .failure("Need head and both shoulders in frame.", nil)
        }

        let shoulderWidth = distance(leftShoulder.location, rightShoulder.location)
        guard shoulderWidth.isFinite, shoulderWidth >= 0.12 else {
            return .failure("Move back until both shoulders are visible.", nil)
        }

        let leftEye = optionalPoint(.leftEye, in: points)
        let rightEye = optionalPoint(.rightEye, in: points)
        let shoulderMidY = (leftShoulder.location.y + rightShoulder.location.y) / 2
        let headY = headAnchorY(nose: nose, leftEye: leftEye, rightEye: rightEye, faceSignal: faceSignal)
        let headPoint = nose?.location ?? faceSignal.map { CGPoint(x: $0.centerX, y: $0.centerY) }
        let neckDistance = (headY - shoulderMidY) / shoulderWidth
        guard neckDistance.isFinite, neckDistance > 0, neckDistance < 4 else {
            return .failure("Posture geometry is unreliable.", nil)
        }

        let closeness: Double
        if let baseline, baseline.hasBodyBaseline {
            closeness = shoulderWidth / baseline.shoulderWidth
        } else {
            closeness = 1
        }

        let headConfidence = nose?.confidence ?? faceSignal?.confidence ?? 0
        let confidence = min(headConfidence, leftShoulder.confidence, rightShoulder.confidence)
        let metrics = PostureMetrics(
            source: .body,
            neckDistance: neckDistance,
            shoulderWidth: shoulderWidth,
            closeness: closeness,
            shoulderTiltDegrees: shoulderTiltDegrees(leftShoulder.location, rightShoulder.location),
            faceCenterY: faceSignal?.centerY,
            faceWidth: faceSignal?.width,
            confidence: confidence,
            timestamp: now
        )
        let pose = PoseFrame(
            source: .body,
            nose: headPoint,
            leftEye: leftEye?.location,
            rightEye: rightEye?.location,
            leftShoulder: leftShoulder.location,
            rightShoulder: rightShoulder.location,
            faceCenter: faceSignal.map { CGPoint(x: $0.centerX, y: $0.centerY) },
            faceSize: faceSignal.map { CGSize(width: $0.width, height: $0.height) },
            confidence: confidence,
            timestamp: now
        )

        return .success(metrics, pose)
    }

    private func rawBodyProbe(
        from points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        rejectReason: String?
    ) -> RawBodyProbe {
        let nose = rawPoint(.nose, in: points)
        let leftEye = rawPoint(.leftEye, in: points)
        let rightEye = rawPoint(.rightEye, in: points)
        let leftShoulder = rawPoint(.leftShoulder, in: points)
        let rightShoulder = rawPoint(.rightShoulder, in: points)

        let shoulderWidth: Double?
        if let leftShoulder, let rightShoulder {
            shoulderWidth = distance(leftShoulder.location, rightShoulder.location)
        } else {
            shoulderWidth = nil
        }

        let neckDistance: Double?
        if let leftShoulder, let rightShoulder, let shoulderWidth, shoulderWidth > 0 {
            let shoulderMidY = (leftShoulder.location.y + rightShoulder.location.y) / 2
            let headY = headAnchorY(nose: nose, leftEye: leftEye, rightEye: rightEye, faceSignal: nil)
            neckDistance = Double((headY - shoulderMidY)) / shoulderWidth
        } else {
            neckDistance = nil
        }

        let candidateConfidence: Double?
        if let nose, let leftShoulder, let rightShoulder {
            candidateConfidence = Double(min(nose.confidence, leftShoulder.confidence, rightShoulder.confidence))
        } else {
            candidateConfidence = nil
        }

        return RawBodyProbe(
            noseConfidence: nose.map { Double($0.confidence) },
            leftEyeConfidence: leftEye.map { Double($0.confidence) },
            rightEyeConfidence: rightEye.map { Double($0.confidence) },
            leftShoulderConfidence: leftShoulder.map { Double($0.confidence) },
            rightShoulderConfidence: rightShoulder.map { Double($0.confidence) },
            shoulderWidth: shoulderWidth,
            neckDistance: neckDistance,
            candidateConfidence: candidateConfidence,
            rejectReason: rejectReason
        )
    }

    private func bodyObservationDiagnostics(
        from points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        validCandidate: Bool,
        rejectReason: String?
    ) -> PostureBodyObservationDiagnostics {
        let probe = rawBodyProbe(from: points, rejectReason: rejectReason)
        var joints: [String: PostureJointDiagnostics] = [:]

        for (joint, point) in points {
            guard point.location.x.isFinite, point.location.y.isFinite else { continue }
            joints[String(describing: joint)] = PostureJointDiagnostics(
                x: Double(point.location.x),
                y: Double(point.location.y),
                confidence: Double(point.confidence)
            )
        }

        return PostureBodyObservationDiagnostics(
            validCandidate: validCandidate,
            rejectReason: rejectReason,
            shoulderWidth: probe.shoulderWidth,
            neckDistance: probe.neckDistance,
            candidateConfidence: probe.candidateConfidence,
            joints: joints
        )
    }

    private func recordRawBodyProbe(_ probe: RawBodyProbe) {
        let currentProbe = RawBodyProbe(
            noseConfidence: lastFrameDiagnostics.rawNoseConfidence,
            leftEyeConfidence: lastFrameDiagnostics.rawLeftEyeConfidence,
            rightEyeConfidence: lastFrameDiagnostics.rawRightEyeConfidence,
            leftShoulderConfidence: lastFrameDiagnostics.rawLeftShoulderConfidence,
            rightShoulderConfidence: lastFrameDiagnostics.rawRightShoulderConfidence,
            shoulderWidth: lastFrameDiagnostics.rawShoulderWidth,
            neckDistance: nil,
            candidateConfidence: nil,
            rejectReason: lastFrameDiagnostics.rawRejectReason
        )

        guard lastFrameDiagnostics.rawNoseConfidence == nil || probe.score >= currentProbe.score else {
            return
        }

        lastFrameDiagnostics.rawNoseConfidence = probe.noseConfidence
        lastFrameDiagnostics.rawLeftEyeConfidence = probe.leftEyeConfidence
        lastFrameDiagnostics.rawRightEyeConfidence = probe.rightEyeConfidence
        lastFrameDiagnostics.rawLeftShoulderConfidence = probe.leftShoulderConfidence
        lastFrameDiagnostics.rawRightShoulderConfidence = probe.rightShoulderConfidence
        lastFrameDiagnostics.rawShoulderWidth = probe.shoulderWidth
        lastFrameDiagnostics.rawRejectReason = probe.rejectReason
    }

    private func makePosePlaceholder(metrics: PostureMetrics, now: Date) -> PoseFrame {
        PoseFrame(
            source: metrics.source,
            nose: nil,
            leftEye: nil,
            rightEye: nil,
            leftShoulder: nil,
            rightShoulder: nil,
            faceCenter: metrics.faceCenterY.map { CGPoint(x: 0.5, y: $0) },
            faceSize: metrics.faceWidth.map { CGSize(width: $0, height: $0) },
            confidence: metrics.confidence,
            timestamp: now
        )
    }

    private func bodyScore(metrics: PostureMetrics, pose: PoseFrame?, faceSignal: FaceSignal?) -> Double {
        let confidenceScore = Double(metrics.confidence) * 3
        let shoulderScore = min(1.5, metrics.shoulderWidth / 0.30)
        let centerScore: Double

        if let nose = pose?.nose {
            centerScore = 1 - min(1, abs(Double(nose.x) - 0.5) * 2)
        } else {
            centerScore = 0
        }

        var faceMatchScore: Double = 0
        if let faceSignal {
            if let nose = pose?.nose {
                let dx = abs(Double(nose.x) - faceSignal.centerX)
                let dy = abs(Double(nose.y) - faceSignal.centerY)
                faceMatchScore += 4 * (1 - min(1, dx / 0.22))
                faceMatchScore += 1.5 * (1 - min(1, dy / 0.36))
            }

            if let leftShoulder = pose?.leftShoulder, let rightShoulder = pose?.rightShoulder {
                let shoulderMidX = Double((leftShoulder.x + rightShoulder.x) / 2)
                let shoulderMidY = Double((leftShoulder.y + rightShoulder.y) / 2)
                let shoulderDx = abs(shoulderMidX - faceSignal.centerX)
                let headAboveShoulders = faceSignal.centerY > shoulderMidY ? 1.0 : -2.0
                faceMatchScore += 3 * (1 - min(1, shoulderDx / 0.26))
                faceMatchScore += headAboveShoulders
            }

            if faceMatchScore < 0 {
                faceMatchScore *= 2
            }
        }

        let baselineScaleScore: Double
        if let baseline, baseline.hasBodyBaseline {
            let ratio = metrics.shoulderWidth / baseline.shoulderWidth
            if ratio < 0.40 || ratio > 1.90 {
                baselineScaleScore = -2
            } else if ratio < 0.55 || ratio > 1.55 {
                baselineScaleScore = -0.75
            } else {
                baselineScaleScore = 0.75
            }
        } else {
            baselineScaleScore = 0
        }

        return confidenceScore + shoulderScore + centerScore + faceMatchScore + baselineScaleScore
    }

    private func headAnchorY(
        nose: VNRecognizedPoint?,
        leftEye: VNRecognizedPoint?,
        rightEye: VNRecognizedPoint?,
        faceSignal: FaceSignal?
    ) -> CGFloat {
        guard let nose else {
            return CGFloat(faceSignal?.centerY ?? 0)
        }

        guard let leftEye, let rightEye else {
            return nose.location.y
        }

        return nose.location.y * 0.5 + leftEye.location.y * 0.25 + rightEye.location.y * 0.25
    }

    private func bestFaceSignal(
        rectanglesRequest: VNDetectFaceRectanglesRequest,
        landmarksRequest: VNDetectFaceLandmarksRequest
    ) -> FaceSignal? {
        let faces = (rectanglesRequest.results ?? []) + (landmarksRequest.results ?? [])

        guard let face = faces.max(by: { first, second in
            first.boundingBox.width * first.boundingBox.height <
                second.boundingBox.width * second.boundingBox.height
        }) else {
            return nil
        }

        let box = face.boundingBox
        guard box.midY.isFinite, box.width.isFinite, box.midY > 0, box.width > 0 else {
            return nil
        }

        return FaceSignal(
            centerX: Double(box.midX),
            centerY: Double(box.midY),
            width: Double(box.width),
            height: Double(box.height),
            confidence: face.confidence
        )
    }

    private func makeFacePose(from face: FaceSignal, now: Date) -> PoseFrame {
        PoseFrame(
            source: .face,
            nose: nil,
            leftEye: nil,
            rightEye: nil,
            leftShoulder: nil,
            rightShoulder: nil,
            faceCenter: CGPoint(x: face.centerX, y: face.centerY),
            faceSize: CGSize(width: face.width, height: face.height),
            confidence: face.confidence,
            timestamp: now
        )
    }

    private func reliablePoint(
        _ joint: VNHumanBodyPoseObservation.JointName,
        in points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    ) -> VNRecognizedPoint? {
        guard let point = points[joint], point.confidence >= minimumJointConfidence else {
            return nil
        }

        guard point.location.x.isFinite, point.location.y.isFinite else {
            return nil
        }

        return point
    }

    private func optionalPoint(
        _ joint: VNHumanBodyPoseObservation.JointName,
        in points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    ) -> VNRecognizedPoint? {
        guard let point = points[joint], point.confidence >= minimumJointConfidence else {
            return nil
        }

        guard point.location.x.isFinite, point.location.y.isFinite else {
            return nil
        }

        return point
    }

    private func rawPoint(
        _ joint: VNHumanBodyPoseObservation.JointName,
        in points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    ) -> VNRecognizedPoint? {
        guard let point = points[joint] else {
            return nil
        }

        guard point.location.x.isFinite, point.location.y.isFinite else {
            return nil
        }

        return point
    }

    private func collectOrientationSweepIfNeeded(
        from sampleBuffer: CMSampleBuffer,
        mode: OrientationSweepMode
    ) {
        #if DEBUG
        switch mode {
        case .calibration:
            guard calibrationOrientationSweepCount < calibrationOrientationSweepLimit else { return }
            calibrationOrientationSweepCount += 1
        case .tracking:
            guard trackingOrientationSweepCount < trackingOrientationSweepLimit else { return }
            trackingOrientationSweepCount += 1
        }

        // Visible face with unusable body geometry may be an EXIF orientation
        // mismatch. Re-run the same frame with every orientation in debug builds
        // only; this records evidence without changing posture decisions.
        lastFrameDiagnostics.orientationSweepResults = orientationSweepOptions.map {
            orientationDiagnostics(for: sampleBuffer, name: $0.name, orientation: $0.orientation)
        }
        #endif
    }

    private var orientationSweepOptions: [(name: String, orientation: CGImagePropertyOrientation)] {
        [
            ("up", .up),
            ("upMirrored", .upMirrored),
            ("left", .left),
            ("leftMirrored", .leftMirrored),
            ("right", .right),
            ("rightMirrored", .rightMirrored),
            ("down", .down),
            ("downMirrored", .downMirrored)
        ]
    }

    private func orientationDiagnostics(
        for sampleBuffer: CMSampleBuffer,
        name: String,
        orientation: CGImagePropertyOrientation
    ) -> PostureOrientationDiagnostics {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return PostureOrientationDiagnostics(
                orientation: name,
                bodyObservationCount: 0,
                validBodyCandidateCount: 0,
                noseConfidence: nil,
                leftEyeConfidence: nil,
                rightEyeConfidence: nil,
                leftShoulderConfidence: nil,
                rightShoulderConfidence: nil,
                shoulderWidth: nil,
                neckDistance: nil,
                candidateConfidence: nil,
                rejectReason: "Vision failed: \(error.localizedDescription)",
                observations: []
            )
        }

        let observations = request.results ?? []
        guard !observations.isEmpty else {
            return PostureOrientationDiagnostics(
                orientation: name,
                bodyObservationCount: 0,
                validBodyCandidateCount: 0,
                noseConfidence: nil,
                leftEyeConfidence: nil,
                rightEyeConfidence: nil,
                leftShoulderConfidence: nil,
                rightShoulderConfidence: nil,
                shoulderWidth: nil,
                neckDistance: nil,
                candidateConfidence: nil,
                rejectReason: "No body observations.",
                observations: []
            )
        }

        var bestProbe: RawBodyProbe?
        var validCandidateCount = 0
        var observationDiagnostics: [PostureBodyObservationDiagnostics] = []

        for observation in observations {
            do {
                let points = try observation.recognizedPoints(.all)
                let probe: RawBodyProbe
                let validCandidate: Bool
                let rejectReason: String?

                switch makeBodyCandidate(from: points, faceSignal: nil, now: Date()) {
                case .success:
                    validCandidateCount += 1
                    validCandidate = true
                    rejectReason = nil
                    probe = rawBodyProbe(from: points, rejectReason: nil)
                case .failure(let reason, _):
                    validCandidate = false
                    rejectReason = reason
                    probe = rawBodyProbe(from: points, rejectReason: reason)
                }

                observationDiagnostics.append(
                    bodyObservationDiagnostics(
                        from: points,
                        validCandidate: validCandidate,
                        rejectReason: rejectReason
                    )
                )

                if bestProbe == nil || probe.score > bestProbe!.score {
                    bestProbe = probe
                }
            } catch {
                let probe = RawBodyProbe(
                    noseConfidence: nil,
                    leftEyeConfidence: nil,
                    rightEyeConfidence: nil,
                    leftShoulderConfidence: nil,
                    rightShoulderConfidence: nil,
                    shoulderWidth: nil,
                    neckDistance: nil,
                    candidateConfidence: nil,
                    rejectReason: "Vision joints unavailable."
                )
                observationDiagnostics.append(
                    PostureBodyObservationDiagnostics(
                        validCandidate: false,
                        rejectReason: "Vision joints unavailable.",
                        shoulderWidth: nil,
                        neckDistance: nil,
                        candidateConfidence: nil,
                        joints: [:]
                    )
                )

                if bestProbe == nil || probe.score > bestProbe!.score {
                    bestProbe = probe
                }
            }
        }

        let probe = bestProbe
        return PostureOrientationDiagnostics(
            orientation: name,
            bodyObservationCount: observations.count,
            validBodyCandidateCount: validCandidateCount,
            noseConfidence: probe?.noseConfidence,
            leftEyeConfidence: probe?.leftEyeConfidence,
            rightEyeConfidence: probe?.rightEyeConfidence,
            leftShoulderConfidence: probe?.leftShoulderConfidence,
            rightShoulderConfidence: probe?.rightShoulderConfidence,
            shoulderWidth: probe?.shoulderWidth,
            neckDistance: probe?.neckDistance,
            candidateConfidence: probe?.candidateConfidence,
            rejectReason: probe?.rejectReason,
            observations: observationDiagnostics
        )
    }

    private func handleMotionSkippedFrame(
        config: PostureDecisionConfig,
        now: Date
    ) -> PostureAnalysisResult {
        if unreliableSince != nil {
            return unreliableResult(
                reason: "Need head and both shoulders in frame.",
                pose: lastReliablePose,
                config: config,
                now: now
            )
        }

        if let lastReliableMetrics {
            let status = decideStatus(for: lastReliableMetrics, config: config, now: now)
            return PostureAnalysisResult(
                status: status,
                metrics: nil,
                pose: lastReliablePose,
                acceptedFrame: false,
                reason: nil
            )
        }

        return PostureAnalysisResult(
            status: currentStatus,
            metrics: nil,
            pose: nil,
            acceptedFrame: false,
            reason: nil
        )
    }

    private func handleUnreliableFrame(
        reason: String,
        pose: PoseFrame?,
        config: PostureDecisionConfig,
        now: Date
    ) -> PostureAnalysisResult {
        if unreliableSince == nil {
            unreliableSince = now
        }

        return unreliableResult(reason: reason, pose: pose, config: config, now: now)
    }

    private func unreliableResult(
        reason: String,
        pose: PoseFrame?,
        config: PostureDecisionConfig,
        now: Date
    ) -> PostureAnalysisResult {
        if let unreliableSince, now.timeIntervalSince(unreliableSince) >= config.unreliableSeconds {
            currentStatus = .cannotSee
            slouchCandidateSince = nil
            recoveryCandidateSince = nil

            return PostureAnalysisResult(
                status: .cannotSee,
                metrics: nil,
                pose: pose,
                acceptedFrame: false,
                reason: reason
            )
        }

        return PostureAnalysisResult(
            status: currentStatus,
            metrics: nil,
            pose: pose,
            acceptedFrame: false,
            reason: reason
        )
    }

    private func decideStatus(
        for metrics: PostureMetrics,
        config: PostureDecisionConfig,
        now: Date
    ) -> PostureStatus {
        guard let baseline, baseline.hasBodyBaseline else {
            currentStatus = .good
            slouchCandidateSince = nil
            recoveryCandidateSince = nil
            return currentStatus
        }

        guard let decision = postureDecision(for: metrics, baseline: baseline, config: config) else {
            return currentStatus
        }

        if currentStatus == .slouching {
            slouchCandidateSince = nil

            if decision.isRecovered {
                if recoveryCandidateSince == nil {
                    recoveryCandidateSince = now
                }

                if let recoveryCandidateSince,
                   now.timeIntervalSince(recoveryCandidateSince) >= config.recoverSeconds {
                    currentStatus = .good
                    self.recoveryCandidateSince = nil
                }
            } else {
                recoveryCandidateSince = nil
            }
        } else {
            recoveryCandidateSince = nil

            if decision.isSlouching {
                if slouchCandidateSince == nil {
                    slouchCandidateSince = now
                }

                if let slouchCandidateSince,
                   now.timeIntervalSince(slouchCandidateSince) >= config.holdSeconds {
                    currentStatus = .slouching
                    self.slouchCandidateSince = nil
                } else if currentStatus == .cannotSee {
                    currentStatus = .good
                }
            } else {
                slouchCandidateSince = nil
                currentStatus = .good
            }
        }

        return currentStatus
    }

    private func postureDecision(
        for metrics: PostureMetrics,
        baseline: PostureBaseline,
        config: PostureDecisionConfig
    ) -> (isSlouching: Bool, isRecovered: Bool)? {
        let closenessThreshold = config.closenessThreshold

        switch metrics.source {
        case .body:
            guard baseline.hasBodyBaseline else { return nil }

            let slouchThreshold = baseline.neckDistance * (1 - config.dropThreshold)
            let recoveryThreshold = baseline.neckDistance * (1 - config.dropThreshold * 0.6)
            let leaned = metrics.closeness > closenessThreshold &&
                metrics.neckDistance < baseline.neckDistance * 0.98
            let severeLean = metrics.closeness > closenessThreshold + 0.12 &&
                metrics.neckDistance < baseline.neckDistance * 1.02

            return (
                metrics.neckDistance < slouchThreshold || leaned || severeLean,
                metrics.neckDistance >= recoveryThreshold &&
                    (metrics.closeness <= closenessThreshold * 0.97 ||
                        metrics.neckDistance >= baseline.neckDistance * 1.02)
            )

        case .face:
            return nil
        }
    }

    private func resetDecisionState() {
        currentStatus = .good
        slouchCandidateSince = nil
        recoveryCandidateSince = nil
        unreliableSince = nil
        lastReliableMetrics = nil
        lastReliablePose = nil
        // A new baseline/run should collect fresh live failure evidence instead
        // of keeping an old sweep-limit count.
        trackingOrientationSweepCount = 0
        motionGate.reset()
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> Double {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return sqrt(Double(dx * dx + dy * dy))
    }

    private func shoulderTiltDegrees(_ leftShoulder: CGPoint, _ rightShoulder: CGPoint) -> Double {
        let dx = rightShoulder.x - leftShoulder.x
        let dy = rightShoulder.y - leftShoulder.y
        var degrees = atan2(Double(dy), Double(dx)) * 180 / .pi

        while degrees > 90 {
            degrees -= 180
        }

        while degrees < -90 {
            degrees += 180
        }

        return degrees
    }
}
