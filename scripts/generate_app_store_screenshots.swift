#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasWidth = 2560
private let canvasHeight = 1600
private let outputDirectory = URL(fileURLWithPath: "docs/app-store/screenshots", isDirectory: true)

private struct ScreenshotSpec {
    let filename: String
    let headline: String
    let subhead: String
    let state: DemoState
}

private enum DemoState {
    case good
    case calibration
    case slouching
    case privacy
}

private struct DemoValues {
    let state: DemoState
    let badge: String
    let guidance: String?
    let score: String
    let neckValue: String
    let neckDetail: String
    let closenessValue: String
    let confidence: String
    let shoulder: String
    let sampling: String
    let inPosition: String
    let calibrateTitle: String
    let sensitivity: String
    let nudgeFiring: Bool
    let slouchDrop: String?
    let headlineColor: NSColor

    static func values(for state: DemoState) -> DemoValues {
        switch state {
        case .good:
            return DemoValues(
                state: state,
                badge: "Good posture",
                guidance: nil,
                score: "93",
                neckValue: "1.08",
                neckDetail: "above 2%",
                closenessValue: "1.02x",
                confidence: "91%",
                shoulder: "254 px",
                sampling: "15 Hz",
                inPosition: "4:12",
                calibrateTitle: "Recalibrate",
                sensitivity: "Normal - drop 10%",
                nudgeFiring: false,
                slouchDrop: nil,
                headlineColor: Palette.good
            )
        case .calibration:
            return DemoValues(
                state: state,
                badge: "Needs calibration",
                guidance: "Click Calibrate once your head and both shoulders are visible.",
                score: "--",
                neckValue: "--",
                neckDetail: "calibrate to start",
                closenessValue: "--",
                confidence: "--",
                shoulder: "--",
                sampling: "15 Hz",
                inPosition: "0:00",
                calibrateTitle: "Calibrate",
                sensitivity: "Normal - drop 10%",
                nudgeFiring: false,
                slouchDrop: nil,
                headlineColor: Palette.info
            )
        case .slouching:
            return DemoValues(
                state: state,
                badge: "Slouching",
                guidance: nil,
                score: "54",
                neckValue: "0.88",
                neckDetail: "drop 17%",
                closenessValue: "1.21x",
                confidence: "88%",
                shoulder: "287 px",
                sampling: "15 Hz",
                inPosition: "0:08",
                calibrateTitle: "Recalibrate",
                sensitivity: "Normal - drop 10%",
                nudgeFiring: true,
                slouchDrop: "Sit up - head dropped 17%",
                headlineColor: Palette.slouch
            )
        case .privacy:
            return DemoValues(
                state: state,
                badge: "Good posture",
                guidance: "Camera frames are processed on this Mac. Release builds do not write camera frames to disk.",
                score: "90",
                neckValue: "1.06",
                neckDetail: "above 1%",
                closenessValue: "1.01x",
                confidence: "90%",
                shoulder: "249 px",
                sampling: "1.5 Hz",
                inPosition: "8:31",
                calibrateTitle: "Recalibrate",
                sensitivity: "Normal - drop 10%",
                nudgeFiring: false,
                slouchDrop: nil,
                headlineColor: Palette.good
            )
        }
    }
}

private enum Palette {
    static let desktopTop = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.92, alpha: 1)
    static let desktopBottom = NSColor(calibratedRed: 0.67, green: 0.75, blue: 0.76, alpha: 1)
    static let panel = NSColor(calibratedWhite: 0.985, alpha: 1)
    static let panelStroke = NSColor(calibratedWhite: 0.74, alpha: 1)
    static let controlFill = NSColor(calibratedWhite: 0.94, alpha: 1)
    static let text = NSColor(calibratedWhite: 0.12, alpha: 1)
    static let secondary = NSColor(calibratedWhite: 0.42, alpha: 1)
    static let tertiary = NSColor(calibratedWhite: 0.62, alpha: 1)
    static let video = NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.100, alpha: 1)
    static let good = NSColor(calibratedRed: 0.114, green: 0.620, blue: 0.459, alpha: 1)
    static let goodText = NSColor(calibratedRed: 0.055, green: 0.365, blue: 0.286, alpha: 1)
    static let slouch = NSColor(calibratedRed: 0.847, green: 0.353, blue: 0.188, alpha: 1)
    static let slouchText = NSColor(calibratedRed: 0.580, green: 0.220, blue: 0.105, alpha: 1)
    static let warn = NSColor(calibratedRed: 0.937, green: 0.624, blue: 0.153, alpha: 1)
    static let info = NSColor(calibratedRed: 0.216, green: 0.541, blue: 0.867, alpha: 1)
    static let white = NSColor.white
}

private final class ScreenshotRenderer {
    private let width = CGFloat(canvasWidth)
    private let height = CGFloat(canvasHeight)

    func render(_ spec: ScreenshotSpec) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: canvasWidth,
            pixelsHigh: canvasHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [.alphaFirst],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer {
            NSGraphicsContext.current = nil
            NSGraphicsContext.restoreGraphicsState()
        }

        drawDesktop(spec: spec)
        drawMenuBar()
        drawPanel(values: .values(for: spec.state), x: 150, y: 170, scale: 1.55)
        drawMarketingCopy(spec: spec, x: 1440, y: 385, width: 760)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        return data
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x, y: height - y - h, width: w, height: h)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: height - y)
    }

    private func fillRounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: radius, yRadius: radius).fill()
    }

    private func strokeRounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat, color: NSColor, lineWidth: CGFloat = 1) {
        color.setStroke()
        let path = NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth
        path.stroke()
    }

    private func drawText(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        h: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = Palette.text,
        alignment: NSTextAlignment = .left,
        monospaced: Bool = false
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let font = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        NSAttributedString(string: text, attributes: attributes).draw(in: rect(x, y, w, h))
    }

    private func drawDesktop(spec: ScreenshotSpec) {
        NSGradient(colors: [Palette.desktopTop, Palette.desktopBottom])?.draw(in: rect(0, 0, width, height), angle: -90)

        let horizon = rect(0, 1050, width, 550)
        NSColor(calibratedWhite: 0.82, alpha: 0.34).setFill()
        horizon.fill()

        for index in 0..<7 {
            let x = CGFloat(index) * 420 - 80
            let y = CGFloat(900 + (index % 3) * 62)
            drawLine(points: [
                CGPoint(x: x, y: y),
                CGPoint(x: x + 310, y: y - 190),
                CGPoint(x: x + 720, y: y - 18)
            ], color: NSColor.white.withAlphaComponent(0.18), lineWidth: 2)
        }

        fillRounded(132, 122, 1130, 1000, radius: 26, color: NSColor.black.withAlphaComponent(0.18))
    }

    private func drawMenuBar() {
        fillRounded(0, 0, width, 56, radius: 0, color: NSColor.white.withAlphaComponent(0.78))
        NSColor(calibratedWhite: 0.62, alpha: 0.35).setStroke()
        let line = NSBezierPath()
        line.move(to: point(0, 56))
        line.line(to: point(width, 56))
        line.lineWidth = 1
        line.stroke()

        drawText("Sloucher", x: 118, y: 15, w: 150, h: 26, size: 18, weight: .semibold)
        drawText("File", x: 292, y: 15, w: 80, h: 26, size: 17, color: Palette.secondary)
        drawText("Edit", x: 368, y: 15, w: 80, h: 26, size: 17, color: Palette.secondary)
        drawText("View", x: 444, y: 15, w: 80, h: 26, size: 17, color: Palette.secondary)
        drawText("Sloucher", x: 1244, y: 15, w: 104, h: 26, size: 17, weight: .medium)
        drawText("Tue 9:41 AM", x: 2252, y: 15, w: 180, h: 26, size: 17, color: Palette.secondary, alignment: .right)
    }

    private func drawMarketingCopy(spec: ScreenshotSpec, x: CGFloat, y: CGFloat, width: CGFloat) {
        let stateColor = DemoValues.values(for: spec.state).headlineColor
        fillRounded(x, y - 76, 96, 8, radius: 4, color: stateColor)
        drawText(spec.headline, x: x, y: y, w: width, h: 190, size: 70, weight: .bold)
        drawText(spec.subhead, x: x, y: y + 220, w: width * 0.88, h: 150, size: 28, color: Palette.secondary)

        let bullets: [String]
        switch spec.state {
        case .good:
            bullets = ["Menu-bar only", "Live posture metrics", "Quiet until posture drops"]
        case .calibration:
            bullets = ["Personal baseline", "Head and shoulders guide", "Recalibrate anytime"]
        case .slouching:
            bullets = ["Notification", "Sound", "Screen glow"]
        case .privacy:
            bullets = ["On-device Vision processing", "No cloud account", "No camera upload"]
        }

        for (index, bullet) in bullets.enumerated() {
            let by = y + 438 + CGFloat(index) * 58
            fillRounded(x, by + 11, 26, 26, radius: 13, color: stateColor.withAlphaComponent(0.16))
            drawCheckmark(x: x + 7, y: by + 17, color: stateColor, scale: 1.0)
            drawText(bullet, x: x + 46, y: by, w: width - 60, h: 42, size: 28, weight: .medium, color: Palette.text)
        }
    }

    private func drawPanel(values: DemoValues, x: CGFloat, y: CGFloat, scale: CGFloat) {
        let innerMargin = 18 * scale
        let innerPadding = 14 * scale
        let innerWidth: CGFloat = 680 * scale
        let innerHeight: CGFloat = 735 * scale
        let w = innerWidth + innerMargin * 2
        let h = innerHeight + innerMargin * 2

        fillRounded(x, y, w, h, radius: 24, color: NSColor.black.withAlphaComponent(0.12))
        fillRounded(x + innerMargin, y + innerMargin, innerWidth, innerHeight, radius: 18, color: Palette.panel)
        strokeRounded(x + innerMargin, y + innerMargin, innerWidth, innerHeight, radius: 18, color: Palette.panelStroke.withAlphaComponent(0.75), lineWidth: 1)

        let px = x + innerMargin + innerPadding
        var cursor = y + innerMargin + innerPadding
        drawPanelHeader(values: values, x: px, y: cursor, scale: scale)
        cursor += 74 * scale

        if let guidance = values.guidance {
            drawGuidance(guidance, state: values.state, x: px, y: cursor, w: 630 * scale, scale: scale)
            cursor += 48 * scale
        }

        drawMainArea(values: values, x: px, y: cursor, scale: scale)
        cursor += 268 * scale
        drawSparkline(values: values, x: px, y: cursor + 14 * scale, scale: scale)
        cursor += 112 * scale
        drawInspectorControls(values: values, x: px, y: cursor + 22 * scale, scale: scale)
        cursor += 97 * scale
        drawUtilityControls(x: px, y: cursor + 18 * scale, scale: scale)
    }

    private func drawPanelHeader(values: DemoValues, x: CGFloat, y: CGFloat, scale: CGFloat) {
        fillRounded(x, y + 4 * scale, 30 * scale, 30 * scale, radius: 7 * scale, color: Palette.good.withAlphaComponent(0.14))
        drawSeatedGlyph(x: x + 7 * scale, y: y + 10 * scale, color: Palette.good, scale: scale)
        drawText("Sloucher", x: x + 40 * scale, y: y + 2 * scale, w: 180 * scale, h: 24 * scale, size: 15 * scale, weight: .medium)
        drawText("Live view", x: x + 40 * scale, y: y + 26 * scale, w: 180 * scale, h: 22 * scale, size: 12 * scale, color: Palette.secondary)

        drawBadge(values.badge, state: values.state, x: x + 330 * scale, y: y + 6 * scale, scale: scale)
        drawNudgeChips(firing: values.nudgeFiring, x: x + 472 * scale, y: y + 6 * scale, scale: scale)
        drawScore(values.score, state: values.state, x: x + 588 * scale, y: y - 4 * scale, scale: scale)
    }

    private func drawGuidance(_ guidance: String, state: DemoState, x: CGFloat, y: CGFloat, w: CGFloat, scale: CGFloat) {
        let fill = state == .calibration ? Palette.info : Palette.secondary
        fillRounded(x, y, w, 34 * scale, radius: 8 * scale, color: fill.withAlphaComponent(0.12))
        strokeRounded(x, y, w, 34 * scale, radius: 8 * scale, color: fill.withAlphaComponent(0.20), lineWidth: 1)
        drawText(guidance, x: x + 12 * scale, y: y + 8 * scale, w: w - 24 * scale, h: 20 * scale, size: 12 * scale, weight: .medium, color: state == .calibration ? Palette.info : Palette.secondary)
    }

    private func drawMainArea(values: DemoValues, x: CGFloat, y: CGFloat, scale: CGFloat) {
        drawVideo(values: values, x: x, y: y, w: 349 * scale, h: 250 * scale, scale: scale)
        drawMetrics(values: values, x: x + 361 * scale, y: y, w: 291 * scale, scale: scale)
    }

    private func drawVideo(values: DemoValues, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, scale: CGFloat) {
        fillRounded(x, y, w, h, radius: 10 * scale, color: Palette.video)
        drawVideoGrid(x: x, y: y, w: w, h: h)

        if values.state == .calibration {
            drawText("Calibrate once to start posture detection.", x: x + 52 * scale, y: y + 106 * scale, w: w - 104 * scale, h: 56 * scale, size: 12 * scale, weight: .medium, color: NSColor.white.withAlphaComponent(0.82), alignment: .center)
        } else {
            drawSyntheticPerson(values: values, x: x, y: y, w: w, h: h, scale: scale)
            drawBaselineLine(values: values, x: x, y: y, w: w, h: h, scale: scale)
        }

        if let slouchDrop = values.slouchDrop {
            fillRounded(x + 8 * scale, y + 8 * scale, w - 16 * scale, 24 * scale, radius: 12 * scale, color: Palette.slouch.withAlphaComponent(0.92))
            drawText(slouchDrop, x: x + 18 * scale, y: y + 11 * scale, w: w - 36 * scale, h: 18 * scale, size: 12 * scale, weight: .medium, color: Palette.white, alignment: .center)
        }

        drawCornerBrackets(x: x, y: y, w: w, h: h, color: values.nudgeFiring ? Palette.slouch : NSColor.white.withAlphaComponent(0.45), scale: scale)
        drawNudgeChips(firing: values.nudgeFiring, x: x + w - 90 * scale, y: y + h - 34 * scale, scale: scale * 0.85)
        strokeRounded(x, y, w, h, radius: 10 * scale, color: NSColor.white.withAlphaComponent(0.08), lineWidth: 1)
    }

    private func drawVideoGrid(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        for fraction in [CGFloat(0.25), CGFloat(0.5), CGFloat(0.75)] {
            drawLine(points: [CGPoint(x: x + w * fraction, y: y), CGPoint(x: x + w * fraction, y: y + h)], color: NSColor.white.withAlphaComponent(0.05), lineWidth: 1)
            drawLine(points: [CGPoint(x: x, y: y + h * fraction), CGPoint(x: x + w, y: y + h * fraction)], color: NSColor.white.withAlphaComponent(0.05), lineWidth: 1)
        }
    }

    private func drawSyntheticPerson(values: DemoValues, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, scale: CGFloat) {
        let slouch = values.state == .slouching
        let skeleton = slouch ? NSColor(calibratedRed: 0.941, green: 0.600, blue: 0.482, alpha: 1) : NSColor(calibratedRed: 0.365, green: 0.792, blue: 0.647, alpha: 1)
        let skin = NSColor(calibratedRed: 0.79, green: 0.69, blue: 0.58, alpha: 1)
        let shirt = slouch ? Palette.slouch.withAlphaComponent(0.34) : Palette.good.withAlphaComponent(0.34)

        let shoulderY = y + h * 0.66
        let leftShoulder = CGPoint(x: x + w * 0.31, y: shoulderY)
        let rightShoulder = CGPoint(x: x + w * 0.69, y: shoulderY)
        let headCenter = CGPoint(x: x + w * (slouch ? 0.54 : 0.50), y: y + h * (slouch ? 0.42 : 0.34))
        let neck = CGPoint(x: x + w * 0.50, y: y + h * 0.58)

        fillRounded(x + w * 0.27, y + h * 0.63, w * 0.46, h * 0.30, radius: 36 * scale, color: shirt)
        fillOval(center: headCenter, diameter: 48 * scale, color: skin.withAlphaComponent(0.72))
        drawLine(points: [leftShoulder, rightShoulder], color: skeleton, lineWidth: 2.5 * scale)
        drawLine(points: [headCenter, neck], color: skeleton, lineWidth: 2.5 * scale)
        drawLine(points: [CGPoint(x: headCenter.x - 13 * scale, y: headCenter.y - 2 * scale), CGPoint(x: headCenter.x + 13 * scale, y: headCenter.y - 2 * scale)], color: skeleton, lineWidth: 2 * scale)

        for point in [leftShoulder, rightShoulder, headCenter, CGPoint(x: headCenter.x - 13 * scale, y: headCenter.y - 2 * scale), CGPoint(x: headCenter.x + 13 * scale, y: headCenter.y - 2 * scale)] {
            fillOval(center: point, diameter: 7 * scale, color: skeleton)
        }
    }

    private func drawBaselineLine(values: DemoValues, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, scale: CGFloat) {
        let baselineY = y + h * 0.36
        drawDashedLine(from: CGPoint(x: x, y: baselineY), to: CGPoint(x: x + w, y: baselineY), color: NSColor.white.withAlphaComponent(0.35), lineWidth: 1, dash: [5 * scale, 5 * scale])
        fillRounded(x + 16 * scale, baselineY - 18 * scale, 122 * scale, 20 * scale, radius: 10 * scale, color: NSColor.black.withAlphaComponent(0.22))
        drawText("calibrated head line", x: x + 22 * scale, y: baselineY - 15 * scale, w: 112 * scale, h: 14 * scale, size: 11 * scale, color: NSColor.white.withAlphaComponent(0.62))
    }

    private func drawMetrics(values: DemoValues, x: CGFloat, y: CGFloat, w: CGFloat, scale: CGFloat) {
        drawMetricReadout(title: "Neck distance", value: values.neckValue, detail: values.neckDetail, active: values.state != .calibration, bad: values.state == .slouching, x: x, y: y, w: w, scale: scale, fill: values.state == .slouching ? 0.37 : 0.72)
        drawMetricReadout(title: "Lean / closeness", value: values.closenessValue, detail: "threshold 1.18x", active: values.state != .calibration, bad: values.state == .slouching, x: x, y: y + 79 * scale, w: w, scale: scale, fill: values.state == .slouching ? 0.82 : 0.22)

        let cardY = y + 158 * scale
        drawStatCard(label: "Conf", value: values.confidence, x: x, y: cardY, w: 139 * scale, scale: scale)
        drawStatCard(label: "Shldr", value: values.shoulder, x: x + 147 * scale, y: cardY, w: 139 * scale, scale: scale)
        drawStatCard(label: "Smpl", value: values.sampling, x: x, y: cardY + 62 * scale, w: 139 * scale, scale: scale)
        drawStatCard(label: "In pos", value: values.inPosition, x: x + 147 * scale, y: cardY + 62 * scale, w: 139 * scale, scale: scale)
    }

    private func drawMetricReadout(title: String, value: String, detail: String, active: Bool, bad: Bool, x: CGFloat, y: CGFloat, w: CGFloat, scale: CGFloat, fill: CGFloat) {
        drawText(title, x: x, y: y, w: 112 * scale, h: 20 * scale, size: 12 * scale, color: Palette.secondary)
        drawText(value, x: x + 132 * scale, y: y - 1 * scale, w: 64 * scale, h: 22 * scale, size: 14 * scale, weight: .medium, monospaced: true)
        drawText(detail, x: x + 198 * scale, y: y, w: 92 * scale, h: 20 * scale, size: 12 * scale, weight: .medium, color: bad ? Palette.slouch : Palette.secondary)
        let barY = y + 30 * scale
        fillRounded(x, barY, w, 16 * scale, radius: 6 * scale, color: Palette.secondary.withAlphaComponent(0.15))
        if active {
            fillRounded(x, barY, max(6 * scale, w * fill), 16 * scale, radius: 6 * scale, color: bad ? Palette.slouch : Palette.good)
        }
        fillRounded(x + w * 0.68, barY - 2 * scale, 2 * scale, 20 * scale, radius: 1, color: Palette.secondary.withAlphaComponent(0.90))
        fillRounded(x + w * 0.44, barY - 2 * scale, 2 * scale, 20 * scale, radius: 1, color: Palette.slouch.withAlphaComponent(0.90))
    }

    private func drawStatCard(label: String, value: String, x: CGFloat, y: CGFloat, w: CGFloat, scale: CGFloat) {
        fillRounded(x, y, w, 54 * scale, radius: 10 * scale, color: Palette.controlFill)
        drawText(label, x: x + 10 * scale, y: y + 8 * scale, w: w - 20 * scale, h: 16 * scale, size: 11 * scale, color: Palette.secondary)
        drawText(value, x: x + 10 * scale, y: y + 27 * scale, w: w - 20 * scale, h: 18 * scale, size: 13 * scale, weight: .medium, monospaced: true)
    }

    private func drawSparkline(values: DemoValues, x: CGFloat, y: CGFloat, scale: CGFloat) {
        let w = 652 * scale
        let h = 86 * scale
        fillRounded(x, y, w, h, radius: 10 * scale, color: Palette.controlFill)
        drawText("Neck distance vs slouch threshold", x: x + 10 * scale, y: y + 9 * scale, w: 260 * scale, h: 18 * scale, size: 12 * scale, color: Palette.secondary)
        drawText("last 12 s", x: x + w - 88 * scale, y: y + 9 * scale, w: 78 * scale, h: 18 * scale, size: 12 * scale, color: Palette.tertiary, alignment: .right, monospaced: true)

        let graphX = x + 12 * scale
        let graphY = y + 36 * scale
        let graphW = w - 24 * scale
        let graphH = 34 * scale
        drawDashedLine(from: CGPoint(x: graphX, y: graphY + graphH * 0.60), to: CGPoint(x: graphX + graphW, y: graphY + graphH * 0.60), color: Palette.slouch.withAlphaComponent(0.55), lineWidth: 1, dash: [4 * scale, 4 * scale])
        drawLine(points: [
            CGPoint(x: graphX, y: graphY + graphH * 0.22),
            CGPoint(x: graphX + graphW * 0.18, y: graphY + graphH * 0.25),
            CGPoint(x: graphX + graphW * 0.34, y: graphY + graphH * 0.28),
            CGPoint(x: graphX + graphW * 0.52, y: graphY + (values.state == .slouching ? graphH * 0.66 : graphH * 0.31)),
            CGPoint(x: graphX + graphW * 0.70, y: graphY + (values.state == .slouching ? graphH * 0.78 : graphH * 0.30)),
            CGPoint(x: graphX + graphW, y: graphY + (values.state == .slouching ? graphH * 0.72 : graphH * 0.26))
        ], color: values.state == .slouching ? Palette.slouch : Palette.good, lineWidth: 2 * scale)
    }

    private func drawInspectorControls(values: DemoValues, x: CGFloat, y: CGFloat, scale: CGFloat) {
        let buttonColor = values.state == .calibration ? Palette.info : Palette.controlFill
        let buttonText = values.state == .calibration ? Palette.white : Palette.text
        fillRounded(x, y, 116 * scale, 32 * scale, radius: 7 * scale, color: buttonColor)
        strokeRounded(x, y, 116 * scale, 32 * scale, radius: 7 * scale, color: Palette.panelStroke, lineWidth: 1)
        drawText(values.calibrateTitle, x: x + 12 * scale, y: y + 7 * scale, w: 94 * scale, h: 18 * scale, size: 13 * scale, weight: .medium, color: buttonText, alignment: .center)

        drawText("Sensitivity", x: x + 128 * scale, y: y + 8 * scale, w: 80 * scale, h: 18 * scale, size: 12 * scale, color: Palette.secondary)
        drawSlider(x: x + 214 * scale, y: y + 14 * scale, w: 190 * scale, scale: scale)
        drawText(values.sensitivity, x: x + 416 * scale, y: y + 8 * scale, w: 170 * scale, h: 18 * scale, size: 12 * scale, weight: .medium, monospaced: true)

        let toggleY = y + 48 * scale
        drawCheckbox(label: "Notifications", checked: true, x: x, y: toggleY, scale: scale)
        drawCheckbox(label: "Sound", checked: true, x: x + 142 * scale, y: toggleY, scale: scale)
        drawCheckbox(label: "Screen glow", checked: true, x: x + 238 * scale, y: toggleY, scale: scale)
    }

    private func drawUtilityControls(x: CGFloat, y: CGFloat, scale: CGFloat) {
        drawCheckbox(label: "Launch at login", checked: false, x: x, y: y + 8 * scale, scale: scale)
        let names = ["Pause", "Snooze 20 min", "Test nudge", "Quit"]
        let widths: [CGFloat] = [68, 114, 94, 56]
        var right = x + 652 * scale
        for index in stride(from: names.count - 1, through: 0, by: -1) {
            let bw = widths[index] * scale
            right -= bw
            fillRounded(right, y, bw, 32 * scale, radius: 7 * scale, color: Palette.controlFill)
            strokeRounded(right, y, bw, 32 * scale, radius: 7 * scale, color: Palette.panelStroke, lineWidth: 1)
            drawText(names[index], x: right + 8 * scale, y: y + 8 * scale, w: bw - 16 * scale, h: 18 * scale, size: 13 * scale, alignment: .center)
            right -= 8 * scale
        }
    }

    private func drawBadge(_ text: String, state: DemoState, x: CGFloat, y: CGFloat, scale: CGFloat) {
        let color: NSColor
        let textColor: NSColor
        switch state {
        case .good, .privacy:
            color = Palette.good
            textColor = Palette.goodText
        case .slouching:
            color = Palette.slouch
            textColor = Palette.slouchText
        case .calibration:
            color = Palette.secondary
            textColor = Palette.secondary
        }
        let badgeFont = NSFont.systemFont(ofSize: 12 * scale, weight: .medium)
        let measuredWidth = (text as NSString).size(withAttributes: [.font: badgeFont]).width
        let w = max(118 * scale, measuredWidth + 24 * scale)
        fillRounded(x, y, w, 28 * scale, radius: 14 * scale, color: color.withAlphaComponent(0.16))
        strokeRounded(x, y, w, 28 * scale, radius: 14 * scale, color: color.withAlphaComponent(0.24), lineWidth: 1)
        drawText(text, x: x + 12 * scale, y: y + 6 * scale, w: w - 24 * scale, h: 17 * scale, size: 12 * scale, weight: .medium, color: textColor, alignment: .center)
    }

    private func drawNudgeChips(firing: Bool, x: CGFloat, y: CGFloat, scale: CGFloat) {
        for index in 0..<3 {
            let cx = x + CGFloat(index) * 34 * scale
            let fill = firing ? Palette.slouch.withAlphaComponent(0.16) : Palette.secondary.withAlphaComponent(0.08)
            let stroke = firing ? Palette.slouch.withAlphaComponent(0.42) : Palette.secondary.withAlphaComponent(0.12)
            fillRounded(cx, y, 28 * scale, 28 * scale, radius: 7 * scale, color: fill)
            strokeRounded(cx, y, 28 * scale, 28 * scale, radius: 7 * scale, color: stroke, lineWidth: 1)
            drawChipIcon(index: index, x: cx + 7 * scale, y: y + 8 * scale, color: firing ? Palette.slouch : Palette.secondary, scale: scale)
        }
    }

    private func drawScore(_ score: String, state: DemoState, x: CGFloat, y: CGFloat, scale: CGFloat) {
        let color: NSColor
        switch state {
        case .slouching:
            color = Palette.slouch
        case .calibration:
            color = Palette.secondary.withAlphaComponent(0.35)
        default:
            color = Palette.good
        }
        fillOval(center: CGPoint(x: x + 28 * scale, y: y + 28 * scale), diameter: 56 * scale, color: Palette.secondary.withAlphaComponent(0.16), strokeOnly: true, lineWidth: 6 * scale)
        fillOval(center: CGPoint(x: x + 28 * scale, y: y + 28 * scale), diameter: 56 * scale, color: color, strokeOnly: true, lineWidth: 6 * scale)
        drawText(score, x: x, y: y + 15 * scale, w: 56 * scale, h: 22 * scale, size: 16 * scale, weight: .medium, alignment: .center, monospaced: true)
    }

    private func drawSlider(x: CGFloat, y: CGFloat, w: CGFloat, scale: CGFloat) {
        fillRounded(x, y, w, 4 * scale, radius: 2 * scale, color: Palette.secondary.withAlphaComponent(0.22))
        fillRounded(x, y, w * 0.50, 4 * scale, radius: 2 * scale, color: Palette.good.withAlphaComponent(0.85))
        fillOval(center: CGPoint(x: x + w * 0.50, y: y + 2 * scale), diameter: 14 * scale, color: Palette.white)
        fillOval(center: CGPoint(x: x + w * 0.50, y: y + 2 * scale), diameter: 14 * scale, color: Palette.panelStroke, strokeOnly: true, lineWidth: 1)
    }

    private func drawCheckbox(label: String, checked: Bool, x: CGFloat, y: CGFloat, scale: CGFloat) {
        fillRounded(x, y + 1 * scale, 16 * scale, 16 * scale, radius: 3 * scale, color: checked ? Palette.good : Palette.white)
        strokeRounded(x, y + 1 * scale, 16 * scale, 16 * scale, radius: 3 * scale, color: checked ? Palette.good : Palette.panelStroke, lineWidth: 1)
        if checked {
            drawCheckmark(x: x + 4 * scale, y: y + 5 * scale, color: Palette.white, scale: scale * 0.65)
        }
        drawText(label, x: x + 22 * scale, y: y, w: 128 * scale, h: 20 * scale, size: 12 * scale)
    }

    private func drawSeatedGlyph(x: CGFloat, y: CGFloat, color: NSColor, scale: CGFloat) {
        fillOval(center: CGPoint(x: x + 11 * scale, y: y + 4 * scale), diameter: 8 * scale, color: color)
        drawLine(points: [CGPoint(x: x + 10 * scale, y: y + 10 * scale), CGPoint(x: x + 8 * scale, y: y + 21 * scale)], color: color, lineWidth: 2.2 * scale)
        drawLine(points: [CGPoint(x: x + 8 * scale, y: y + 21 * scale), CGPoint(x: x + 21 * scale, y: y + 21 * scale)], color: color, lineWidth: 2.2 * scale)
    }

    private func drawChipIcon(index: Int, x: CGFloat, y: CGFloat, color: NSColor, scale: CGFloat) {
        switch index {
        case 0:
            drawLine(points: [CGPoint(x: x + 3 * scale, y: y + 8 * scale), CGPoint(x: x + 7 * scale, y: y + 3 * scale), CGPoint(x: x + 11 * scale, y: y + 8 * scale)], color: color, lineWidth: 1.7 * scale)
            fillRounded(x + 4 * scale, y + 8 * scale, 10 * scale, 8 * scale, radius: 4 * scale, color: color.withAlphaComponent(0.9))
        case 1:
            drawLine(points: [CGPoint(x: x + 2 * scale, y: y + 7 * scale), CGPoint(x: x + 6 * scale, y: y + 7 * scale), CGPoint(x: x + 11 * scale, y: y + 3 * scale), CGPoint(x: x + 11 * scale, y: y + 15 * scale), CGPoint(x: x + 6 * scale, y: y + 11 * scale), CGPoint(x: x + 2 * scale, y: y + 11 * scale)], color: color, lineWidth: 1.7 * scale)
            drawLine(points: [CGPoint(x: x + 14 * scale, y: y + 4 * scale), CGPoint(x: x + 17 * scale, y: y + 8 * scale), CGPoint(x: x + 14 * scale, y: y + 14 * scale)], color: color, lineWidth: 1.4 * scale)
        default:
            strokeRounded(x + 2 * scale, y + 2 * scale, 15 * scale, 13 * scale, radius: 2 * scale, color: color, lineWidth: 1.7 * scale)
            drawDashedLine(from: CGPoint(x: x + 2 * scale, y: y + 9 * scale), to: CGPoint(x: x + 17 * scale, y: y + 9 * scale), color: color, lineWidth: 1.2 * scale, dash: [2 * scale, 2 * scale])
        }
    }

    private func drawCornerBrackets(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: NSColor, scale: CGFloat) {
        let inset = 10 * scale
        let arm = 22 * scale
        let points: [[CGPoint]] = [
            [CGPoint(x: x + inset + arm, y: y + inset), CGPoint(x: x + inset, y: y + inset), CGPoint(x: x + inset, y: y + inset + arm)],
            [CGPoint(x: x + w - inset - arm, y: y + inset), CGPoint(x: x + w - inset, y: y + inset), CGPoint(x: x + w - inset, y: y + inset + arm)],
            [CGPoint(x: x + inset, y: y + h - inset - arm), CGPoint(x: x + inset, y: y + h - inset), CGPoint(x: x + inset + arm, y: y + h - inset)],
            [CGPoint(x: x + w - inset - arm, y: y + h - inset), CGPoint(x: x + w - inset, y: y + h - inset), CGPoint(x: x + w - inset, y: y + h - inset - arm)]
        ]
        for segment in points {
            drawLine(points: segment, color: color, lineWidth: 2 * scale)
        }
    }

    private func drawCheckmark(x: CGFloat, y: CGFloat, color: NSColor, scale: CGFloat) {
        drawLine(points: [
            CGPoint(x: x, y: y + 7 * scale),
            CGPoint(x: x + 5 * scale, y: y + 12 * scale),
            CGPoint(x: x + 15 * scale, y: y)
        ], color: color, lineWidth: 2.2 * scale)
    }

    private func drawLine(points: [CGPoint], color: NSColor, lineWidth: CGFloat) {
        guard let first = points.first else { return }
        color.setStroke()
        let path = NSBezierPath()
        path.move(to: point(first.x, first.y))
        for item in points.dropFirst() {
            path.line(to: point(item.x, item.y))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = lineWidth
        path.stroke()
    }

    private func drawDashedLine(from: CGPoint, to: CGPoint, color: NSColor, lineWidth: CGFloat, dash: [CGFloat]) {
        color.setStroke()
        let path = NSBezierPath()
        path.move(to: point(from.x, from.y))
        path.line(to: point(to.x, to.y))
        path.lineWidth = lineWidth
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.stroke()
    }

    private func fillOval(center: CGPoint, diameter: CGFloat, color: NSColor, strokeOnly: Bool = false, lineWidth: CGFloat = 1) {
        let path = NSBezierPath(ovalIn: rect(center.x - diameter / 2, center.y - diameter / 2, diameter, diameter))
        if strokeOnly {
            color.setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        } else {
            color.setFill()
            path.fill()
        }
    }
}

private let specs = [
    ScreenshotSpec(
        filename: "01-good-posture.png",
        headline: "Posture coaching from the menu bar",
        subhead: "Calibrate once, then let Sloucher watch quietly while you work.",
        state: .good
    ),
    ScreenshotSpec(
        filename: "02-calibrate-baseline.png",
        headline: "Set your own upright baseline",
        subhead: "Sloucher compares posture changes against how you actually sit at your desk.",
        state: .calibration
    ),
    ScreenshotSpec(
        filename: "03-nudge-when-slouching.png",
        headline: "Get nudged when posture drops",
        subhead: "Notifications, sound, and screen glow help you correct slouching before it sticks.",
        state: .slouching
    ),
    ScreenshotSpec(
        filename: "04-private-on-device.png",
        headline: "Private, local posture checks",
        subhead: "Camera frames stay on your Mac and are processed on-device with Apple's Vision framework.",
        state: .privacy
    )
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
private let renderer = ScreenshotRenderer()

for spec in specs {
    let data = try renderer.render(spec)
    let url = outputDirectory.appendingPathComponent(spec.filename)
    try data.write(to: url, options: .atomic)
    print("Wrote \(url.path)")
}
