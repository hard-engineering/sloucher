import AVFoundation
import CoreVideo
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
    private var consecutiveFailureFrameCount = 0
    private var forcedVisionAttemptsSinceFailure = 0
    // Short rolling buffers (≈1s of accepted frames) for median-smoothing the two
    // body measurements the decision depends on. The padded detector's shoulder
    // width can swing ±17% across head poses; smoothing keeps a single wide frame
    // from tripping the lean threshold and faking a head-drop at once.
    private var recentShoulderWidths: [Double] = []
    private var recentVerticalGaps: [Double] = []
    private let metricSmoothingSampleCount = 15

    private enum OrientationSweepMode {
        case calibration
        case tracking
    }

    // Coordinate-agnostic joint sample. The full-frame path adapts Vision's
    // VNRecognizedPoint into this; the padding-rescue path injects points whose
    // coordinates have been remapped from the padded buffer back to the original
    // frame. Letting every candidate helper work on JointPoint keeps a single
    // gate/scoring implementation for both paths.
    private struct JointPoint {
        let location: CGPoint
        let confidence: VNConfidence
    }

    private typealias JointPoints = [VNHumanBodyPoseObservation.JointName: JointPoint]

    // Taller-canvas pad factor for the on-failure rescue: the real frame occupies
    // the top 1/1.6 of the buffer, gray fills the rest. Chosen from offline
    // replay of captured failures (rescue plateaued ~1.3-2.0; 1.6 had the best
    // metric fidelity). Inverse map: original_y = 1.6*padded_y - 0.6.
    private let paddingRescueFactor: Double = 1.6

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
        let box: PostureRectDiagnostics
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
        let gateDiagnostics = motionGate.evaluate(
            sampleBuffer: sampleBuffer,
            forceInference: shouldForceInference
        )
        recordMotionGateDiagnostics(gateDiagnostics)

        guard gateDiagnostics.shouldRunInference else {
            lastFrameDiagnostics.bodyFailureReason = "Motion gate skipped inference."
            recordFailureRunDiagnostics()
            return handleMotionSkippedFrame(config: config, now: now)
        }

        switch extractMetrics(
            from: sampleBuffer,
            now: now,
            collectCalibrationDiagnostics: collectCalibrationDiagnostics,
            collectTrackingDiagnostics: collectTrackingDiagnostics,
            paddingRescueEnabled: config.paddingRescueEnabled
        ) {
        case .success(let rawMetrics, let pose):
            // Smooth shoulder width and the head-shoulder gap before they reach the
            // decision; the pose overlay still gets the raw points.
            let metrics = smoothedMetrics(from: rawMetrics)
            unreliableSince = nil
            lastReliableMetrics = metrics
            lastReliablePose = pose
            consecutiveFailureFrameCount = 0
            forcedVisionAttemptsSinceFailure = 0
            recordFailureRunDiagnostics()
            #if DEBUG
            // A valid frame starts a new diagnostic episode; future visible-face
            // failures should still get orientation retry evidence.
            trackingOrientationSweepCount = 0
            #endif
            let status = decideStatus(for: metrics, config: config, now: now)

            return PostureAnalysisResult(
                status: status,
                metrics: metrics,
                pose: pose,
                acceptedFrame: true,
                reason: nil
            )

        case .failure(let reason, let pose):
            consecutiveFailureFrameCount += 1
            if shouldForceInference {
                forcedVisionAttemptsSinceFailure += 1
            }
            recordFailureRunDiagnostics()
            return handleUnreliableFrame(reason: reason, pose: pose, config: config, now: now)
        }
    }

    func resetCalibrationDebugDiagnostics() {
        calibrationOrientationSweepCount = 0
        // Start calibration with a clean smoothing window so pre-calibration
        // tracking values don't leak into the baseline samples.
        resetMetricSmoothing()
    }

    func resetTrackingDebugDiagnostics() {
        trackingOrientationSweepCount = 0
    }

    private func recordMotionGateDiagnostics(_ diagnostics: FrameMotionGateDiagnostics) {
        lastFrameDiagnostics.forceInference = diagnostics.forceInference
        lastFrameDiagnostics.motionGateSkipped = diagnostics.skipped
        lastFrameDiagnostics.motionGateMeanAbsoluteDifference = diagnostics.meanAbsoluteDifference
        lastFrameDiagnostics.motionGateThreshold = diagnostics.threshold
        lastFrameDiagnostics.motionGateHadPreviousFrame = diagnostics.hadPreviousFrame
        lastFrameDiagnostics.motionGateFrameHash = diagnostics.frameHash
    }

    private func recordFailureRunDiagnostics() {
        lastFrameDiagnostics.consecutiveFailureFrameCount = consecutiveFailureFrameCount
        lastFrameDiagnostics.forcedVisionAttemptsSinceFailure = forcedVisionAttemptsSinceFailure
    }

    private func extractMetrics(
        from sampleBuffer: CMSampleBuffer,
        now: Date,
        collectCalibrationDiagnostics: Bool,
        collectTrackingDiagnostics: Bool,
        paddingRescueEnabled: Bool
    ) -> MetricExtractionResult {
        // Face detection on the original frame. We always need the face: it is how
        // the padded body path tells the user from background people, the head
        // anchor, and the face baseline. Body pose is handled separately below so
        // we never run it full-frame when the padded path already found the user.
        // The capture output is intentionally unmirrored; preview mirroring is
        // UI-only. Passing .up keeps Vision's coordinates tied to the camera buffer.
        let faceRequest = VNDetectFaceRectanglesRequest()
        let faceLandmarksRequest = VNDetectFaceLandmarksRequest()
        let faceHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        try? faceHandler.perform([faceRequest, faceLandmarksRequest])

        let faceSignal = bestFaceSignal(
            rectanglesRequest: faceRequest,
            landmarksRequest: faceLandmarksRequest
        )
        lastFrameDiagnostics.faceObservationCount =
            (faceRequest.results?.count ?? 0) + (faceLandmarksRequest.results?.count ?? 0)
        lastFrameDiagnostics.faceDetected = faceSignal != nil
        lastFrameDiagnostics.faceBox = faceSignal?.box
        lastFrameDiagnostics.faceConfidence = faceSignal.map { Double($0.confidence) }
        let facePose = faceSignal.map { makeFacePose(from: $0, now: now) }

        // Primary path: padded body pose. In the laptop "large head, shoulders at
        // the frame edge" framing, full-frame body pose fails ~92% of the time, so
        // trying it first wastes an inference on nearly every frame. Padding
        // reframes the user like a mid-distance person and detects ~98% of those.
        // It needs the face for candidate scoring, so only when a face is present.
        if paddingRescueEnabled, let faceSignal,
           case .success(let metrics, let pose) = detectBodyWithPadding(
               sampleBuffer: sampleBuffer,
               faceSignal: faceSignal,
               now: now
           ) {
            return .success(metrics, pose)
        }

        // Fallback (and the path when padding is disabled or no face is present):
        // full-frame body pose on the original buffer. Recovers the minority of
        // frames where full-frame succeeds but padding does not.
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let bodyHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try bodyHandler.perform([bodyRequest])
        } catch {
            return .failure("Vision failed: \(error.localizedDescription)", facePose)
        }

        switch makeBodyMetrics(from: bodyRequest, faceSignal: faceSignal, now: now) {
        case .success(let metrics, let pose):
            lastFrameDiagnostics.fullFrameSucceeded = true
            return .success(metrics, pose)
        case .failure(let bodyReason, _):
            // Both detectors failed this frame.
            lastFrameDiagnostics.fullFrameBodyFailed = true

            // Gather debug orientation-sweep evidence only when nothing detected
            // the body (capped per episode in debug builds).
            if collectCalibrationDiagnostics, faceSignal != nil {
                collectOrientationSweepIfNeeded(from: sampleBuffer, mode: .calibration)
            } else if collectTrackingDiagnostics, faceSignal != nil {
                collectOrientationSweepIfNeeded(from: sampleBuffer, mode: .tracking)
            }

            return .failure(bodyReason, facePose)
        }
    }

    // MARK: - Padded (primary) body detection

    private func detectBodyWithPadding(
        sampleBuffer: CMSampleBuffer,
        faceSignal: FaceSignal,
        now: Date
    ) -> MetricExtractionResult {
        guard let padded = Self.makePaddedBuffer(from: sampleBuffer, factor: paddingRescueFactor) else {
            return .failure("Padding retry unavailable.", nil)
        }

        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: padded, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failure("Padding retry failed: \(error.localizedDescription)", nil)
        }

        guard let observations = request.results, !observations.isEmpty else {
            return .failure("Padding retry found no body.", nil)
        }

        // Run every padded observation through the same candidate gate and scoring
        // as the full-frame path, after mapping its coordinates back to the
        // original frame. The existing face signal (already in original coords) is
        // reused so face-match scoring still rejects background people.
        var candidates: [BodyCandidate] = []
        for observation in observations {
            guard let rawPoints = try? observation.recognizedPoints(.all) else { continue }
            let points = remapPaddedPoints(rawPoints, factor: paddingRescueFactor)
            switch makeBodyCandidate(from: points, faceSignal: faceSignal, now: now) {
            case .success(let metrics, let pose):
                let resolved = pose ?? makePosePlaceholder(metrics: metrics, now: now)
                candidates.append(
                    BodyCandidate(
                        metrics: metrics,
                        pose: resolved,
                        score: bodyScore(metrics: metrics, pose: resolved, faceSignal: faceSignal),
                        headAnchorSource: resolved.nose == resolved.faceCenter ? "face" : "body"
                    )
                )
            case .failure:
                continue
            }
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else {
            return .failure("Padding retry candidate rejected.", nil)
        }

        // Mark this as a normal valid frame for the decision logic, and record the
        // detection so the runtime probe can measure how often padding is the
        // detector and at what shoulder-width scale (to confirm it matches the
        // baseline, which must be calibrated in the same padded scale).
        lastFrameDiagnostics.bodyFailureReason = nil
        lastFrameDiagnostics.detectedByPadding = true
        lastFrameDiagnostics.rescuePadFactor = paddingRescueFactor
        lastFrameDiagnostics.validBodyCandidateCount = candidates.count
        lastFrameDiagnostics.headAnchorSource = best.headAnchorSource
        lastFrameDiagnostics.bestCandidateScore = best.score
        lastFrameDiagnostics.candidateConfidence = Double(best.metrics.confidence)
        lastFrameDiagnostics.candidateShoulderWidth = best.metrics.shoulderWidth
        lastFrameDiagnostics.candidateNeckDistance = best.metrics.neckDistance
        return .success(best.metrics, best.pose)
    }

    private func remapPaddedPoints(
        _ points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        factor: Double
    ) -> JointPoints {
        // The padded buffer placed the real frame in the top 1/factor of a taller
        // canvas, so a detection at padded-y maps back to original-y by
        // original_y = factor*padded_y - (factor - 1). x is unchanged because the
        // pad only grows height. Points that fall in the gray pad map below 0 and
        // are rejected by the normal geometry gates.
        points.mapValues { point in
            let mappedY = factor * Double(point.location.y) - (factor - 1)
            return JointPoint(
                location: CGPoint(x: point.location.x, y: CGFloat(mappedY)),
                confidence: point.confidence
            )
        }
    }

    private static func jointPoints(
        from points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    ) -> JointPoints {
        points.mapValues { JointPoint(location: $0.location, confidence: $0.confidence) }
    }

    // Build a taller 420f buffer with the source frame copied to the top and the
    // extra rows filled with neutral gray (luma/chroma 128). Lossless byte copy of
    // the camera planes; returns nil if the format is ever not bi-planar 420f.
    private static func makePaddedBuffer(from sampleBuffer: CMSampleBuffer, factor: Double) -> CVPixelBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(source) == 2 else {
            return nil
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        var paddedHeight = Int(Double(height) * factor)
        if paddedHeight % 2 == 1 { paddedHeight += 1 } // chroma plane is half-height

        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, paddedHeight,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary, &pixelBuffer
        ) == kCVReturnSuccess, let destination = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        for plane in 0..<2 {
            guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let destBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                return nil
            }
            let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let destBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let copyBytes = min(sourceBytesPerRow, destBytesPerRow)
            let sourceRows = CVPixelBufferGetHeightOfPlane(source, plane)
            let destRows = CVPixelBufferGetHeightOfPlane(destination, plane)
            let sourceBytes = sourceBase.assumingMemoryBound(to: UInt8.self)
            let destBytes = destBase.assumingMemoryBound(to: UInt8.self)

            for row in 0..<destRows {
                if row < sourceRows {
                    memcpy(
                        destBytes.advanced(by: row * destBytesPerRow),
                        sourceBytes.advanced(by: row * sourceBytesPerRow),
                        copyBytes
                    )
                } else {
                    memset(destBytes.advanced(by: row * destBytesPerRow), 128, destBytesPerRow)
                }
            }
        }

        return destination
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
                let points = Self.jointPoints(from: try observation.recognizedPoints(.all))
                switch makeBodyCandidate(from: points, faceSignal: faceSignal, now: now) {
                case .success(let metrics, let pose):
                    recordRawBodyProbe(rawBodyProbe(from: points, rejectReason: nil))
                    lastFrameDiagnostics.bodyObservations.append(
                        bodyObservationDiagnostics(
                            from: points,
                            validCandidate: true,
                            rejectReason: nil,
                            faceSignal: faceSignal
                        )
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
                        bodyObservationDiagnostics(
                            from: points,
                            validCandidate: false,
                            rejectReason: reason,
                            faceSignal: faceSignal
                        )
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
                        bodyBox: nil,
                        headToFaceDelta: nil,
                        shoulderMidToFaceDelta: nil,
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
        from points: JointPoints,
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
        from points: JointPoints,
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
        from points: JointPoints,
        validCandidate: Bool,
        rejectReason: String?,
        faceSignal: FaceSignal? = nil
    ) -> PostureBodyObservationDiagnostics {
        let probe = rawBodyProbe(from: points, rejectReason: rejectReason)
        var joints: [String: PostureJointDiagnostics] = [:]
        var finitePoints: [CGPoint] = []

        for (joint, point) in points {
            guard point.location.x.isFinite, point.location.y.isFinite else { continue }
            finitePoints.append(point.location)
            joints[String(describing: joint)] = PostureJointDiagnostics(
                x: Double(point.location.x),
                y: Double(point.location.y),
                confidence: Double(point.confidence)
            )
        }

        let faceCenter = faceSignal.map { CGPoint(x: $0.centerX, y: $0.centerY) }
        let headDelta = faceCenter.flatMap { faceCenter in
            diagnosticHeadPoint(in: points).map { pointDelta(from: $0, to: faceCenter) }
        }
        let shoulderDelta = faceCenter.flatMap { faceCenter in
            diagnosticShoulderMidPoint(in: points).map { pointDelta(from: $0, to: faceCenter) }
        }

        return PostureBodyObservationDiagnostics(
            validCandidate: validCandidate,
            rejectReason: rejectReason,
            shoulderWidth: probe.shoulderWidth,
            neckDistance: probe.neckDistance,
            candidateConfidence: probe.candidateConfidence,
            bodyBox: bodyBox(from: finitePoints),
            headToFaceDelta: headDelta,
            shoulderMidToFaceDelta: shoulderDelta,
            joints: joints
        )
    }

    private func diagnosticHeadPoint(
        in points: JointPoints
    ) -> CGPoint? {
        if let nose = rawPoint(.nose, in: points) {
            return nose.location
        }

        let leftEye = rawPoint(.leftEye, in: points)
        let rightEye = rawPoint(.rightEye, in: points)

        switch (leftEye, rightEye) {
        case (.some(let leftEye), .some(let rightEye)):
            return CGPoint(
                x: (leftEye.location.x + rightEye.location.x) / 2,
                y: (leftEye.location.y + rightEye.location.y) / 2
            )
        case (.some(let leftEye), nil):
            return leftEye.location
        case (nil, .some(let rightEye)):
            return rightEye.location
        case (nil, nil):
            return nil
        }
    }

    private func diagnosticShoulderMidPoint(
        in points: JointPoints
    ) -> CGPoint? {
        guard
            let leftShoulder = rawPoint(.leftShoulder, in: points),
            let rightShoulder = rawPoint(.rightShoulder, in: points)
        else {
            return nil
        }

        return CGPoint(
            x: (leftShoulder.location.x + rightShoulder.location.x) / 2,
            y: (leftShoulder.location.y + rightShoulder.location.y) / 2
        )
    }

    private func pointDelta(from point: CGPoint, to target: CGPoint) -> PosturePointDeltaDiagnostics {
        let dx = Double(point.x - target.x)
        let dy = Double(point.y - target.y)
        return PosturePointDeltaDiagnostics(
            dx: dx,
            dy: dy,
            distance: sqrt(dx * dx + dy * dy)
        )
    }

    private func bodyBox(from points: [CGPoint]) -> PostureRectDiagnostics? {
        guard let first = points.first else { return nil }

        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y

        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        return PostureRectDiagnostics(
            minX: Double(minX),
            minY: Double(minY),
            maxX: Double(maxX),
            maxY: Double(maxY)
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
        nose: JointPoint?,
        leftEye: JointPoint?,
        rightEye: JointPoint?,
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
            box: PostureRectDiagnostics(
                minX: Double(box.minX),
                minY: Double(box.minY),
                maxX: Double(box.maxX),
                maxY: Double(box.maxY)
            ),
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
        in points: JointPoints
    ) -> JointPoint? {
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
        in points: JointPoints
    ) -> JointPoint? {
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
        in points: JointPoints
    ) -> JointPoint? {
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
        recordOrientationRetrySummary()
        #endif
    }

    private func recordOrientationRetrySummary() {
        let results = lastFrameDiagnostics.orientationSweepResults
        guard !results.isEmpty else { return }

        let best = results.max { first, second in
            orientationScore(first) < orientationScore(second)
        }
        let upMirrored = results.first { $0.orientation == "upMirrored" }

        lastFrameDiagnostics.orientationRetryBestOrientation = best?.orientation
        lastFrameDiagnostics.orientationRetryBestValidCandidateCount = best?.validBodyCandidateCount
        lastFrameDiagnostics.orientationRetryUpMirroredValidCandidateCount = upMirrored?.validBodyCandidateCount
        lastFrameDiagnostics.orientationRetryUpMirroredShoulderWidth = upMirrored?.shoulderWidth
        lastFrameDiagnostics.orientationRetryUpMirroredRejectReason = upMirrored?.rejectReason
    }

    private func orientationScore(_ result: PostureOrientationDiagnostics) -> Double {
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
                let points = Self.jointPoints(from: try observation.recognizedPoints(.all))
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
                        bodyBox: nil,
                        headToFaceDelta: nil,
                        shoulderMidToFaceDelta: nil,
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
        consecutiveFailureFrameCount = 0
        forcedVisionAttemptsSinceFailure = 0
        // A new baseline/run should collect fresh live failure evidence instead
        // of keeping an old sweep-limit count.
        trackingOrientationSweepCount = 0
        // A new baseline changes the scale; flush smoothing so old-scale widths
        // don't bias the first second of the new run.
        resetMetricSmoothing()
        motionGate.reset()
    }

    // Median-smooth shoulder width and the head-to-shoulder gap over a short
    // window, then recompute neck distance and closeness from the smoothed parts.
    // Median (not mean) is used because the failure mode is occasional wide
    // outlier frames, which a mean would still be dragged by. Smoothing the
    // denominator also stops a single small-width frame from spiking the ratio.
    // Only body metrics are smoothed; face metrics pass through unchanged.
    private func smoothedMetrics(from metrics: PostureMetrics) -> PostureMetrics {
        guard metrics.source == .body, metrics.shoulderWidth.isFinite, metrics.shoulderWidth > 0 else {
            return metrics
        }

        // Recover the vertical gap from the ratio so we can smooth numerator and
        // denominator independently (neckDistance = gap / shoulderWidth).
        let verticalGap = metrics.neckDistance * metrics.shoulderWidth
        recentShoulderWidths.append(metrics.shoulderWidth)
        recentVerticalGaps.append(verticalGap)
        if recentShoulderWidths.count > metricSmoothingSampleCount {
            recentShoulderWidths.removeFirst(recentShoulderWidths.count - metricSmoothingSampleCount)
            recentVerticalGaps.removeFirst(recentVerticalGaps.count - metricSmoothingSampleCount)
        }

        let smoothedShoulderWidth = median(recentShoulderWidths)
        let smoothedGap = median(recentVerticalGaps)
        guard smoothedShoulderWidth > 0 else { return metrics }

        let smoothedCloseness: Double
        if let baseline, baseline.hasBodyBaseline {
            smoothedCloseness = smoothedShoulderWidth / baseline.shoulderWidth
        } else {
            smoothedCloseness = metrics.closeness
        }

        return PostureMetrics(
            source: metrics.source,
            neckDistance: smoothedGap / smoothedShoulderWidth,
            shoulderWidth: smoothedShoulderWidth,
            closeness: smoothedCloseness,
            shoulderTiltDegrees: metrics.shoulderTiltDegrees,
            faceCenterY: metrics.faceCenterY,
            faceWidth: metrics.faceWidth,
            confidence: metrics.confidence,
            timestamp: metrics.timestamp
        )
    }

    private func resetMetricSmoothing() {
        recentShoulderWidths = []
        recentVerticalGaps = []
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
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
