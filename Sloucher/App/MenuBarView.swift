import AppKit
import SwiftUI

struct MainWindowRootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.shouldShowPermissionSetup {
                PermissionsSetupView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical) {
                    MenuBarView()
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 540, alignment: .top)
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            InspectorHeader()

            if let guidance = appState.inspectorGuidanceText {
                InspectorGuidance(text: guidance, status: appState.status)
            }

            HStack(alignment: .top, spacing: 12) {
                WebcamPreview()
                    .frame(width: 349, height: 250)

                MetricsPanel()
                    .frame(width: 291)
            }

            SparklineCard()
                .frame(height: 86)

            InspectorControls()

            UtilityControls()
        }
        .padding(14)
        .frame(width: 680)
        .onAppear {
            appState.setInspectorVisible(true)
        }
        .onDisappear {
            appState.setInspectorVisible(false)
        }
    }
}

private struct InspectorGuidance: View {
    let text: String
    let status: PostureStatus

    var body: some View {
        Label(text, systemImage: iconName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(textColor)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(fillColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(fillColor.opacity(0.20), lineWidth: 1)
            )
            .help(text)
    }

    private var iconName: String {
        switch status {
        case .calibrating:
            "arrow.triangle.2.circlepath"
        case .cannotSee, .uncalibrated:
            "info.circle.fill"
        default:
            "info.circle"
        }
    }

    private var fillColor: Color {
        switch status {
        case .calibrating:
            InspectorColors.info
        case .cannotSee:
            InspectorColors.info
        default:
            .secondary
        }
    }

    private var textColor: Color {
        switch status {
        case .calibrating:
            InspectorColors.infoText
        case .cannotSee:
            InspectorColors.infoText
        default:
            .secondary
        }
    }
}

private struct InspectorHeader: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(InspectorColors.good.opacity(0.14))

                Image(systemName: "figure.seated.side")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(InspectorColors.good)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Sloucher")
                    .font(.system(size: 15, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)

                Text("Live view")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 8)

            StateBadge(status: appState.status, labelText: appState.statusBadgeText)
            NudgeIndicators(
                firing: appState.status == .slouching || appState.isNudgePreviewActive,
                notificationsEnabled: appState.notificationNudgesEnabled,
                soundEnabled: appState.settings.soundEnabled,
                overlayEnabled: appState.settings.overlayEnabled
            )
            ScoreRing(score: ringScore)
        }
    }

    private var ringScore: Int? {
        switch appState.status {
        case .good, .slouching, .paused, .snoozed:
            appState.hasBaseline ? appState.postureScore : nil
        default:
            nil
        }
    }
}

private struct WebcamPreview: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                InspectorColors.videoBackground

                if let image = appState.latestFrameImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        // Mirror the user-facing preview without changing the
                        // sample buffer that Vision and forensic capture inspect.
                        .scaleEffect(x: -1, y: 1)
                } else {
                    EmptyPreviewMessage()
                }

                PreviewGrid()
                SkeletonOverlay(
                    pose: appState.latestPose,
                    slouching: appState.status == .slouching
                )
                // Pose coordinates come from the unmirrored Vision buffer, so mirror
                // this overlay with the preview to keep debugging marks aligned.
                .scaleEffect(x: -1, y: 1)
                BaselineLine(y: appState.baselineHeadY)
                CornerBrackets(slouching: appState.status == .slouching)

                if appState.status == .slouching {
                    VStack {
                        SlouchBanner(percent: appState.currentDropPercent)
                        Spacer()
                    }
                    .padding(8)
                    .transition(.opacity)
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        NudgeIndicators(
                            firing: appState.status == .slouching || appState.isNudgePreviewActive,
                            notificationsEnabled: appState.notificationNudgesEnabled,
                            soundEnabled: appState.settings.soundEnabled,
                            overlayEnabled: appState.settings.overlayEnabled,
                            compact: true
                        )
                    }
                    .padding(8)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityLabel("Live posture preview")
    }
}

private struct EmptyPreviewMessage: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            switch appState.status {
            case .cameraPermissionNeeded:
                if appState.cameraAuthorization == .requesting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting...")
                            .font(.system(size: 11, weight: .medium))
                    }
                } else {
                    Button("Enable Camera") {
                        appState.requestCameraPermission()
                    }
                    .controlSize(.small)
                }
            case .cameraDenied:
                Button("Open System Settings") {
                    appState.openCameraSettings()
                }
                .controlSize(.small)
            case .cameraStarting:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting...")
                        .font(.system(size: 11, weight: .medium))
                }
            case .cameraNoFrames:
                Button("Open System Settings") {
                    appState.openCameraSettings()
                }
                .controlSize(.small)
            default:
                EmptyView()
            }
        }
        .padding(18)
    }

    private var iconName: String {
        switch appState.status {
        case .cameraPermissionNeeded, .cameraDenied, .cameraStarting, .cameraNoFrames, .cameraUnavailable:
            "video.slash"
        case .cannotSee:
            "eye.slash"
        default:
            "camera"
        }
    }

    private var message: String {
        switch appState.status {
        case .cameraPermissionNeeded:
            appState.cameraAuthorization == .requesting
                ? "Waiting for camera permission..."
                : "Camera access is needed."
        case .cameraDenied:
            "Camera access is off."
        case .cameraStarting:
            "Starting the camera..."
        case .cameraNoFrames:
            "Camera is enabled, but no frames are arriving."
        case .cameraUnavailable:
            "No camera was found."
        case .cannotSee:
            "Move into view with your head and shoulders visible."
        case .uncalibrated:
            "Calibrate once to start posture detection."
        default:
            "Waiting for the camera..."
        }
    }
}

private struct PreviewGrid: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                for fraction in [0.25, 0.5, 0.75] {
                    let x = proxy.size.width * fraction
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))

                    let y = proxy.size.height * fraction
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.05), lineWidth: 1)
        }
    }
}

private struct SkeletonOverlay: View {
    let pose: PoseFrame?
    let slouching: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let pose {
                    if pose.source == .body {
                        bodySkeleton(pose: pose, size: proxy.size)
                    } else if let rect = faceRect(pose: pose, size: proxy.size) {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(styleColor.opacity(0.92), lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: slouching)
    }

    private var styleColor: Color {
        slouching ? InspectorColors.skeletonBad : InspectorColors.skeletonGood
    }

    private func bodySkeleton(pose: PoseFrame, size: CGSize) -> some View {
        ZStack {
            Path { path in
                if let left = pose.leftShoulder, let right = pose.rightShoulder {
                    path.move(to: map(left, size: size))
                    path.addLine(to: map(right, size: size))
                }

                if let nose = pose.nose, let left = pose.leftShoulder, let right = pose.rightShoulder {
                    let shoulderMid = CGPoint(
                        x: (left.x + right.x) / 2,
                        y: (left.y + right.y) / 2
                    )
                    path.move(to: map(nose, size: size))
                    path.addLine(to: map(shoulderMid, size: size))
                }

                if let leftEye = pose.leftEye, let rightEye = pose.rightEye {
                    path.move(to: map(leftEye, size: size))
                    path.addLine(to: map(rightEye, size: size))
                }
            }
            .stroke(styleColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            ForEach(Array(nodes(from: pose).enumerated()), id: \.offset) { _, point in
                Circle()
                    .fill(styleColor)
                    .frame(width: 7, height: 7)
                    .position(map(point, size: size))
            }
        }
    }

    private func nodes(from pose: PoseFrame) -> [CGPoint] {
        [pose.nose, pose.leftEye, pose.rightEye, pose.leftShoulder, pose.rightShoulder].compactMap { $0 }
    }

    private func map(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: clamp(Double(point.x), 0, 1) * size.width,
            y: (1 - clamp(Double(point.y), 0, 1)) * size.height
        )
    }

    private func faceRect(pose: PoseFrame, size: CGSize) -> CGRect? {
        guard let center = pose.faceCenter, let faceSize = pose.faceSize else { return nil }
        let width = clamp(Double(faceSize.width), 0, 1) * size.width
        let height = clamp(Double(faceSize.height), 0, 1) * size.height
        let x = clamp(Double(center.x), 0, 1) * size.width
        let y = (1 - clamp(Double(center.y), 0, 1)) * size.height
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }
}

private struct BaselineLine: View {
    let y: Double?

    var body: some View {
        GeometryReader { proxy in
            if let y {
                let mappedY = (1 - clamp(y, 0, 1)) * proxy.size.height

                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: mappedY))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: mappedY))
                    }
                    .stroke(
                        Color.white.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                    )

                    Text("calibrated head line")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.22), in: Capsule())
                        .position(x: 82, y: max(14, mappedY - 10))
                }
            }
        }
    }
}

private struct CornerBrackets: View {
    let slouching: Bool

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let inset: CGFloat = 10
                let arm: CGFloat = 22
                let width = proxy.size.width
                let height = proxy.size.height

                path.move(to: CGPoint(x: inset + arm, y: inset))
                path.addLine(to: CGPoint(x: inset, y: inset))
                path.addLine(to: CGPoint(x: inset, y: inset + arm))

                path.move(to: CGPoint(x: width - inset - arm, y: inset))
                path.addLine(to: CGPoint(x: width - inset, y: inset))
                path.addLine(to: CGPoint(x: width - inset, y: inset + arm))

                path.move(to: CGPoint(x: inset, y: height - inset - arm))
                path.addLine(to: CGPoint(x: inset, y: height - inset))
                path.addLine(to: CGPoint(x: inset + arm, y: height - inset))

                path.move(to: CGPoint(x: width - inset - arm, y: height - inset))
                path.addLine(to: CGPoint(x: width - inset, y: height - inset))
                path.addLine(to: CGPoint(x: width - inset, y: height - inset - arm))
            }
            .stroke(slouching ? InspectorColors.slouch : Color.white.opacity(0.45), lineWidth: 2)
        }
    }
}

private struct SlouchBanner: View {
    let percent: Double?

    var body: some View {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(InspectorColors.slouch.opacity(0.9), in: Capsule())
                .help(text)
    }

    private var text: String {
        guard let percent else { return "Sit up" }
        return "Sit up - head dropped \(abs(percent).formatted(.number.precision(.fractionLength(0))))%"
    }
}

private struct MetricsPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 14) {
            MetricReadout(
                title: "Neck distance",
                valueText: number(appState.liveMetrics?.neckDistance, digits: 2),
                detailText: neckDetail,
                value: appState.liveMetrics?.neckDistance,
                baseline: appState.displayBaselineDistance,
                threshold: appState.slouchThreshold,
                domain: neckDomain,
                slouchWhenLower: true
            )

            MetricReadout(
                title: "Lean / closeness",
                valueText: closenessText,
                detailText: "threshold \(thresholdText)x",
                value: appState.liveMetrics?.closeness,
                baseline: 1,
                threshold: appState.displayClosenessThreshold,
                domain: 0.9...1.3,
                slouchWhenLower: false,
                isOverThresholdOverride: appState.isLeanSignalCurrentlyTriggering
            )

            StatGrid()
        }
        .opacity(appState.status == .cannotSee ? 0.62 : 1)
    }

    private var neckDomain: ClosedRange<Double> {
        let baseline = appState.displayBaselineDistance ?? 1
        return (baseline * 0.7)...(baseline * 1.06)
    }

    private var neckDetail: String {
        guard appState.liveMetrics != nil else {
            return appState.hasBaseline ? "not tracking" : "calibrate to start"
        }
        guard let percent = appState.currentDropPercent else { return "calibrate to start" }
        if percent >= 0 {
            return "drop \(percent.formatted(.number.precision(.fractionLength(0))))%"
        }

        return "above \(abs(percent).formatted(.number.precision(.fractionLength(0))))%"
    }

    private var closenessText: String {
        guard let closeness = appState.liveMetrics?.closeness else { return "--" }
        return "\(closeness.formatted(.number.precision(.fractionLength(2))))x"
    }

    private var thresholdText: String {
        appState.displayClosenessThreshold.formatted(.number.precision(.fractionLength(2)))
    }
}

private struct MetricReadout: View {
    let title: String
    let valueText: String
    let detailText: String
    let value: Double?
    let baseline: Double?
    let threshold: Double?
    let domain: ClosedRange<Double>
    let slouchWhenLower: Bool
    var isOverThresholdOverride: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 8)

                Text(valueText)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)

                Text(detailText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isOverThreshold ? InspectorColors.slouch : .secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .help("\(title): \(valueText), \(detailText)")

            MetricBar(
                value: value,
                baseline: baseline,
                threshold: threshold,
                domain: domain,
                slouchWhenLower: slouchWhenLower,
                isOverThresholdOverride: isOverThresholdOverride
            )
            .frame(height: 16)
        }
    }

    private var isOverThreshold: Bool {
        if let isOverThresholdOverride {
            return isOverThresholdOverride
        }

        guard let value, let threshold else { return false }
        return slouchWhenLower ? value < threshold : value > threshold
    }
}

private struct MetricBar: View {
    let value: Double?
    let baseline: Double?
    let threshold: Double?
    let domain: ClosedRange<Double>
    let slouchWhenLower: Bool
    var isOverThresholdOverride: Bool? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))

                if let value {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOverThreshold(value) ? InspectorColors.slouch : InspectorColors.good)
                        .frame(width: max(6, proxy.size.width * position(value)))
                        .animation(.linear(duration: 0.12), value: value)
                }

                if let baseline {
                    tick(at: baseline, color: .secondary, in: proxy.size)
                }

                if let threshold {
                    tick(at: threshold, color: InspectorColors.slouch, in: proxy.size)
                }
            }
        }
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let value else { return "No value" }
        if let threshold {
            return "Value \(value), threshold \(threshold)"
        }
        return "Value \(value)"
    }

    private func isOverThreshold(_ value: Double) -> Bool {
        if let isOverThresholdOverride {
            return isOverThresholdOverride
        }

        guard let threshold else { return false }
        return slouchWhenLower ? value < threshold : value > threshold
    }

    private func position(_ value: Double) -> CGFloat {
        let span = max(0.0001, domain.upperBound - domain.lowerBound)
        return CGFloat(clamp((value - domain.lowerBound) / span, 0, 1))
    }

    private func tick(at value: Double, color: Color, in size: CGSize) -> some View {
        Rectangle()
            .fill(color.opacity(0.9))
            .frame(width: 2, height: size.height + 4)
            .position(x: size.width * position(value), y: size.height / 2)
    }
}

private struct StatGrid: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatCard(label: "Conf", value: confidenceText)
                StatCard(label: "Shldr", value: shoulderText)
            }

            HStack(spacing: 8) {
                StatCard(label: "Smpl", value: appState.samplingRateText)

                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    StatCard(
                        label: "In pos",
                        value: formatDuration(context.date.timeIntervalSince(appState.statusChangedAt))
                    )
                }
            }
        }
    }

    private var confidenceText: String {
        guard let confidence = appState.liveMetrics?.confidence else { return "--" }
        return "\(Int((confidence * 100).rounded()))%"
    }

    private var shoulderText: String {
        guard let metrics = appState.liveMetrics else { return "--" }

        if let image = appState.latestFrameImage {
            let pixels = Int((metrics.shoulderWidth * Double(image.width)).rounded())
            return "\(pixels) px"
        }

        return metrics.shoulderWidth.formatted(.number.precision(.fractionLength(2)))
    }
}

private struct StatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .help("\(label): \(value)")
    }
}

private struct SparklineCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Neck distance vs slouch threshold")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Neck distance vs slouch threshold")

                Spacer()

                Text("last 12 s")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Last 12 seconds")
            }

            Sparkline(
                samples: appState.metricHistory,
                baseline: appState.displayBaselineDistance,
                threshold: appState.slouchThreshold
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Sparkline: View {
    let samples: [MetricHistorySample]
    let baseline: Double?
    let threshold: Double?

    var body: some View {
        GeometryReader { proxy in
            if samples.count < 2 {
                Text("Waiting for samples")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    if let threshold {
                        thresholdShade(threshold, size: proxy.size)
                    }

                    if let baseline {
                        horizontalLine(value: baseline, color: .secondary, size: proxy.size)
                    }

                    if let threshold {
                        horizontalLine(value: threshold, color: InspectorColors.slouch, dashed: true, size: proxy.size)
                    }

                    trace(size: proxy.size)

                    ForEach(samples) { sample in
                        Circle()
                            .fill(sample.wasSlouching || isBelowThreshold(sample.neckDistance) ? InspectorColors.slouch : InspectorColors.good)
                            .frame(width: 4, height: 4)
                            .position(point(for: sample, size: proxy.size))
                    }
                }
            }
        }
    }

    private var valueBounds: ClosedRange<Double> {
        var values = samples.map(\.neckDistance)
        if let baseline { values.append(baseline) }
        if let threshold { values.append(threshold) }

        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let padding = max(0.02, (maximum - minimum) * 0.2)
        return (minimum - padding)...(maximum + padding)
    }

    private var timeBounds: ClosedRange<Date> {
        let end = samples.last?.timestamp ?? Date()
        return end.addingTimeInterval(-12)...end
    }

    private func trace(size: CGSize) -> some View {
        Path { path in
            for (index, sample) in samples.enumerated() {
                let mapped = point(for: sample, size: size)
                if index == 0 {
                    path.move(to: mapped)
                } else {
                    path.addLine(to: mapped)
                }
            }
        }
        .stroke(InspectorColors.good, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func thresholdShade(_ threshold: Double, size: CGSize) -> some View {
        let y = yPosition(for: threshold, size: size)
        return Rectangle()
            .fill(InspectorColors.slouch.opacity(0.10))
            .frame(width: size.width, height: max(0, size.height - y))
            .position(x: size.width / 2, y: y + max(0, size.height - y) / 2)
    }

    private func horizontalLine(
        value: Double,
        color: Color,
        dashed: Bool = false,
        size: CGSize
    ) -> some View {
        let y = yPosition(for: value, size: size)

        return Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(
            color.opacity(0.55),
            style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 4] : [])
        )
    }

    private func point(for sample: MetricHistorySample, size: CGSize) -> CGPoint {
        let total = max(0.001, timeBounds.upperBound.timeIntervalSince(timeBounds.lowerBound))
        let elapsed = sample.timestamp.timeIntervalSince(timeBounds.lowerBound)
        let x = clamp(elapsed / total, 0, 1) * size.width
        return CGPoint(x: x, y: yPosition(for: sample.neckDistance, size: size))
    }

    private func yPosition(for value: Double, size: CGSize) -> CGFloat {
        let bounds = valueBounds
        let span = max(0.0001, bounds.upperBound - bounds.lowerBound)
        let fraction = clamp((value - bounds.lowerBound) / span, 0, 1)
        return CGFloat((1 - fraction) * size.height)
    }

    private func isBelowThreshold(_ value: Double) -> Bool {
        guard let threshold else { return false }
        return value < threshold
    }
}

private struct InspectorControls: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    calibrationButton
                    sensitivityLabel
                    sensitivitySlider
                    sensitivityValue
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        calibrationButton
                        sensitivityLabel
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 12) {
                        sensitivitySlider
                        sensitivityValue
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    notificationToggle
                    notificationPermissionAction
                    soundToggle
                    screenGlowToggle
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        notificationToggle
                        notificationPermissionAction
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 18) {
                        soundToggle
                        screenGlowToggle
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var calibrationButton: some View {
        Button {
            appState.startCalibration()
        } label: {
            Label(appState.hasBaseline ? "Recalibrate" : "Calibrate", systemImage: "scope")
                .fixedSize(horizontal: true, vertical: false)
        }
        .disabled(!appState.canCalibrate)
        .help(appState.hasBaseline ? "Recalibrate posture baseline" : "Calibrate posture baseline")
    }

    private var sensitivityLabel: some View {
        Text("Sensitivity")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .help("Sensitivity")
    }

    private var sensitivitySlider: some View {
        Slider(value: sensitivityBinding, in: 0...2, step: 1)
            .frame(minWidth: 190)
            .accessibilityLabel("Sensitivity")
            .accessibilityValue(sensitivityText)
            .help("Move right for stricter posture alerts")
    }

    private var sensitivityValue: some View {
        Text(sensitivityText)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .fixedSize(horizontal: true, vertical: false)
            .help(sensitivityText)
    }

    private var notificationToggle: some View {
        Toggle("Notifications", isOn: $appState.settings.notificationsEnabled)
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: true, vertical: false)
            .help("Notifications")
            .onChange(of: appState.settings.notificationsEnabled) { enabled in
                if enabled {
                    appState.requestNotificationPermissionIfNeeded()
                }
            }
    }

    @ViewBuilder
    private var notificationPermissionAction: some View {
        if appState.settings.notificationsEnabled,
           appState.notificationPermissionStatus == .denied {
            Button("Settings") {
                appState.openNotificationSettings()
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .help("Open Notification settings")
        }
    }

    private var soundToggle: some View {
        Toggle("Sound", isOn: $appState.settings.soundEnabled)
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: true, vertical: false)
            .help("Sound")
    }

    private var screenGlowToggle: some View {
        Toggle("Screen glow", isOn: $appState.settings.overlayEnabled)
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: true, vertical: false)
            .help("Screen glow")
    }

    private var sensitivityBinding: Binding<Double> {
        Binding(
            get: { Double(2 - appState.settings.sensitivity.rawValue) },
            set: { newValue in
                let rawValue = 2 - Int(newValue.rounded())
                appState.settings.sensitivity = Sensitivity(rawValue: rawValue) ?? .normal
            }
        )
    }

    private var sensitivityText: String {
        let sensitivity = appState.settings.sensitivity
        let percent = Int((sensitivity.dropThreshold * 100).rounded())
        return "\(sensitivity.displayName) - drop \(percent)%"
    }
}

private struct UtilityControls: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                launchAtLoginToggle
                Spacer()
                utilityButtons
            }

            VStack(alignment: .leading, spacing: 8) {
                launchAtLoginToggle
                utilityButtons
            }
        }
    }

    private var launchAtLoginToggle: some View {
        Toggle("Launch at login", isOn: $appState.launchAtLoginEnabled)
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: true, vertical: false)
            .help("Launch at login")
    }

    private var utilityButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                pauseButton
                snoozeButton
                testNudgeButton
                quitButton
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    pauseButton
                    snoozeButton
                }
                HStack(spacing: 10) {
                    testNudgeButton
                    quitButton
                }
            }
        }
    }

    private var pauseButton: some View {
        Button(appState.isPaused ? "Resume" : "Pause") {
            appState.togglePause()
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(appState.isPaused ? "Resume monitoring" : "Pause monitoring")
    }

    private var snoozeButton: some View {
        Button("Snooze 20 min") {
            appState.snooze(minutes: 20)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("Snooze for 20 minutes")
    }

    private var testNudgeButton: some View {
        Button("Test nudge") {
            appState.testNudge()
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("Test notification, sound, and screen glow")
    }

    private var quitButton: some View {
        Button("Quit") {
            appState.quit()
        }
        .keyboardShortcut("q")
        .fixedSize(horizontal: true, vertical: false)
        .help("Quit Sloucher")
    }
}

private struct StateBadge: View {
    let status: PostureStatus
    let labelText: String

    var body: some View {
        Label(labelText, systemImage: iconName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(textColor)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(fillColor.opacity(0.16), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(fillColor.opacity(0.24), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.2), value: status)
            .help(labelText)
    }

    private var iconName: String {
        switch status {
        case .good:
            "checkmark.circle.fill"
        case .slouching:
            "exclamationmark.triangle.fill"
        case .calibrating:
            "arrow.triangle.2.circlepath"
        case .cannotSee:
            "viewfinder"
        case .cameraPermissionNeeded, .cameraDenied, .cameraStarting, .cameraNoFrames, .cameraUnavailable:
            "video.slash"
        case .paused, .snoozed:
            "pause.circle.fill"
        case .uncalibrated:
            "scope"
        }
    }

    private var fillColor: Color {
        switch status {
        case .good:
            InspectorColors.good
        case .slouching:
            InspectorColors.slouch
        case .calibrating:
            InspectorColors.info
        case .cannotSee, .paused, .snoozed, .uncalibrated,
             .cameraPermissionNeeded, .cameraDenied, .cameraStarting, .cameraNoFrames, .cameraUnavailable:
            .secondary
        }
    }

    private var textColor: Color {
        switch status {
        case .good:
            InspectorColors.goodText
        case .slouching:
            InspectorColors.slouchText
        case .calibrating:
            InspectorColors.infoText
        default:
            .secondary
        }
    }
}

private struct ScoreRing: View {
    let score: Int?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.16), lineWidth: 6)

            Circle()
                .trim(from: 0, to: CGFloat((score ?? 0)) / 100)
                .stroke(
                    bandColor,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: score)

            Text(score.map(String.init) ?? "--")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(score == nil ? .secondary : .primary)
        }
        .frame(width: 56, height: 56)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var bandColor: Color {
        guard let score else { return .secondary.opacity(0.35) }

        if score >= 80 {
            return InspectorColors.good
        } else if score >= 60 {
            return InspectorColors.warn
        }

        return InspectorColors.slouch
    }

    private var accessibilityLabel: String {
        guard let score else { return "Posture score unavailable" }

        let band: String
        if score >= 80 {
            band = "good"
        } else if score >= 60 {
            band = "warning"
        } else {
            band = "slouching"
        }

        return "Posture score \(score) of 100, \(band)"
    }
}

private struct NudgeIndicators: View {
    let firing: Bool
    let notificationsEnabled: Bool
    let soundEnabled: Bool
    let overlayEnabled: Bool
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            nudgeChip(systemName: "bell.fill", enabled: notificationsEnabled)
            nudgeChip(systemName: "speaker.wave.2.fill", enabled: soundEnabled)
            nudgeChip(systemName: "rectangle.dashed", enabled: overlayEnabled)
        }
    }

    private func nudgeChip(systemName: String, enabled: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .foregroundStyle(chipForeground(enabled: enabled))
            .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
            .background(chipBackground(enabled: enabled), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(chipBorder(enabled: enabled), lineWidth: 1)
            )
            .help(helpText(systemName: systemName, enabled: enabled))
            .animation(.easeInOut(duration: 0.2), value: firing)
    }

    private func chipForeground(enabled: Bool) -> Color {
        guard enabled else { return .secondary.opacity(0.45) }
        return firing ? InspectorColors.slouch : .secondary
    }

    private func chipBackground(enabled: Bool) -> Color {
        guard enabled else { return Color.secondary.opacity(0.06) }
        return firing ? InspectorColors.slouch.opacity(0.16) : Color.secondary.opacity(0.08)
    }

    private func chipBorder(enabled: Bool) -> Color {
        guard enabled else { return Color.secondary.opacity(0.08) }
        return firing ? InspectorColors.slouch.opacity(0.42) : Color.secondary.opacity(0.12)
    }

    private func helpText(systemName: String, enabled: Bool) -> String {
        let name: String
        switch systemName {
        case "bell.fill":
            name = "Notification"
        case "speaker.wave.2.fill":
            name = "Sound"
        default:
            name = "Screen glow"
        }

        return enabled ? "\(name) nudge enabled" : "\(name) nudge disabled"
    }
}

private struct PermissionsSetupView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("Sloucher")
                    .font(.system(size: 24, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)

                Text("Set Up Sloucher")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)

                Text("Camera access is required for posture detection.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                PermissionCard(
                    iconName: "camera.fill",
                    title: "Camera",
                    description: "Measures posture locally from your Mac camera.",
                    state: cameraCardState,
                    primaryAction: cameraPrimaryAction,
                    settingsAction: appState.openCameraSettings
                )
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
    }

    private var cameraCardState: PermissionCardState {
        switch appState.cameraAuthorization {
        case .notDetermined:
            .needed(buttonTitle: "Enable Camera")
        case .requesting:
            .requesting
        case .authorized:
            .granted
        case .denied:
            .denied(buttonTitle: "Open System Settings")
        case .unavailable:
            .unavailable
        }
    }

    private var cameraPrimaryAction: () -> Void {
        switch appState.cameraAuthorization {
        case .notDetermined:
            return appState.requestCameraPermission
        case .denied:
            return appState.openCameraSettings
        default:
            return {}
        }
    }
}

private enum PermissionCardState: Equatable {
    case needed(buttonTitle: String)
    case requesting
    case granted
    case denied(buttonTitle: String)
    case unavailable
}

private struct PermissionCard: View {
    let iconName: String
    let title: String
    let description: String
    let state: PermissionCardState
    let primaryAction: () -> Void
    let settingsAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconFill.opacity(0.16))

                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconFill)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            trailingView
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var trailingView: some View {
        switch state {
        case let .needed(buttonTitle):
            Button(buttonTitle) {
                primaryAction()
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
        case .requesting:
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting...")
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: true, vertical: false)
                }

                Button("Open System Settings") {
                    settingsAction()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InspectorColors.goodText)
                .fixedSize(horizontal: true, vertical: false)
        case let .denied(buttonTitle):
            Button(buttonTitle) {
                settingsAction()
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
        case .unavailable:
            Text("No camera found")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var iconFill: Color {
        switch state {
        case .granted:
            InspectorColors.good
        case .requesting:
            InspectorColors.info
        default:
            InspectorColors.warn
        }
    }
}

private enum InspectorColors {
    static let good = Color(red: 0.114, green: 0.620, blue: 0.459)
    static let goodText = Color(red: 0.059, green: 0.431, blue: 0.337)
    static let slouch = Color(red: 0.847, green: 0.353, blue: 0.188)
    static let slouchText = Color(red: 0.600, green: 0.235, blue: 0.114)
    static let warn = Color(red: 0.937, green: 0.624, blue: 0.153)
    static let info = Color(red: 0.216, green: 0.541, blue: 0.867)
    static let infoText = Color(red: 0.094, green: 0.373, blue: 0.647)
    static let videoBackground = Color(red: 0.082, green: 0.090, blue: 0.102)
    static let skeletonGood = Color(red: 0.365, green: 0.792, blue: 0.647)
    static let skeletonBad = Color(red: 0.941, green: 0.600, blue: 0.482)
}

private func number(_ value: Double?, digits: Int) -> String {
    guard let value else { return "--" }
    return value.formatted(.number.precision(.fractionLength(digits)))
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}

private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(upper, max(lower, value))
}
