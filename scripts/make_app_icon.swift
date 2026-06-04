#!/usr/bin/env swift

import AppKit
import Foundation

struct IconVariant {
    let size: Int
    let scale: Int
    let filename: String
}

let variants = [
    IconVariant(size: 16, scale: 1, filename: "icon_16x16.png"),
    IconVariant(size: 16, scale: 2, filename: "icon_16x16@2x.png"),
    IconVariant(size: 32, scale: 1, filename: "icon_32x32.png"),
    IconVariant(size: 32, scale: 2, filename: "icon_32x32@2x.png"),
    IconVariant(size: 128, scale: 1, filename: "icon_128x128.png"),
    IconVariant(size: 128, scale: 2, filename: "icon_128x128@2x.png"),
    IconVariant(size: 256, scale: 1, filename: "icon_256x256.png"),
    IconVariant(size: 256, scale: 2, filename: "icon_256x256@2x.png"),
    IconVariant(size: 512, scale: 1, filename: "icon_512x512.png"),
    IconVariant(size: 512, scale: 2, filename: "icon_512x512@2x.png")
]

let outputDirectory = URL(fileURLWithPath: "Sloucher/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
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

    guard let context = NSGraphicsContext.current?.cgContext else {
        throw CocoaError(.fileWriteUnknown)
    }

    context.clear(CGRect(origin: .zero, size: CGSize(width: pixels, height: pixels)))

    let rect = CGRect(origin: .zero, size: CGSize(width: pixels, height: pixels))
    let radius = CGFloat(pixels) * 0.22
    let background = CGPath(roundedRect: rect.insetBy(dx: CGFloat(pixels) * 0.04, dy: CGFloat(pixels) * 0.04), cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(background)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.14, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.06, green: 0.33, blue: 0.29, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )

    context.resetClip()

    let inset = CGFloat(pixels) * 0.12
    let inner = rect.insetBy(dx: inset, dy: inset)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    context.setStrokeColor(NSColor(calibratedRed: 0.54, green: 0.96, blue: 0.77, alpha: 1).cgColor)
    context.setLineWidth(max(2, CGFloat(pixels) * 0.055))
    context.move(to: CGPoint(x: inner.minX + inner.width * 0.08, y: inner.minY + inner.height * 0.34))
    context.addLine(to: CGPoint(x: inner.maxX - inner.width * 0.10, y: inner.minY + inner.height * 0.34))
    context.strokePath()

    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(max(3, CGFloat(pixels) * 0.075))
    context.move(to: CGPoint(x: inner.minX + inner.width * 0.34, y: inner.minY + inner.height * 0.21))
    context.addCurve(
        to: CGPoint(x: inner.minX + inner.width * 0.48, y: inner.minY + inner.height * 0.70),
        control1: CGPoint(x: inner.minX + inner.width * 0.42, y: inner.minY + inner.height * 0.34),
        control2: CGPoint(x: inner.minX + inner.width * 0.34, y: inner.minY + inner.height * 0.58)
    )
    context.strokePath()

    context.setFillColor(NSColor.white.cgColor)
    let headDiameter = CGFloat(pixels) * 0.17
    let head = CGRect(
        x: inner.minX + inner.width * 0.50,
        y: inner.minY + inner.height * 0.66,
        width: headDiameter,
        height: headDiameter
    )
    context.fillEllipse(in: head)

    context.setStrokeColor(NSColor(calibratedRed: 0.87, green: 0.99, blue: 0.93, alpha: 1).cgColor)
    context.setLineWidth(max(2, CGFloat(pixels) * 0.052))
    context.move(to: CGPoint(x: inner.minX + inner.width * 0.34, y: inner.minY + inner.height * 0.48))
    context.addLine(to: CGPoint(x: inner.minX + inner.width * 0.70, y: inner.minY + inner.height * 0.48))
    context.strokePath()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for variant in variants {
    let pixels = variant.size * variant.scale
    let data = try drawIcon(pixels: pixels)
    try data.write(to: outputDirectory.appendingPathComponent(variant.filename), options: .atomic)
}

print("Wrote \(variants.count) app icon files to \(outputDirectory.path)")
