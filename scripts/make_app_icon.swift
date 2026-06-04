#!/usr/bin/env swift

import AppKit
import Foundation

// Generates all AppIcon.appiconset PNGs plus the MenuBarIcon template imageset.
// Artwork tiers (decided 2026-06): point sizes <= 32 get the bold mark-only
// slouching figure; larger sizes get the desk + monitor scene. The menu bar
// glyph is the mark-only figure as a black template image.
//
// Geometry is authored in a 512x512, y-down design space (matching the SVG
// sources); drawArtwork() flips CoreGraphics' y-up space accordingly.

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

let menuBarVariants = [
    IconVariant(size: 18, scale: 1, filename: "menubar_18.png"),
    IconVariant(size: 18, scale: 2, filename: "menubar_18@2x.png")
]

let appIconDirectory = URL(fileURLWithPath: "Sloucher/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let menuBarDirectory = URL(fileURLWithPath: "Sloucher/Assets.xcassets/MenuBarIcon.imageset", isDirectory: true)

let teal = NSColor(calibratedRed: 0.0549, green: 0.6235, blue: 0.5569, alpha: 1) // #0E9F8E

enum Artwork {
    case markOnly
    case deskScene
}

// Translate/scale that centers each artwork's bounding box in the 512 design tile.
struct Fit {
    let tx: CGFloat
    let ty: CGFloat
    let scale: CGFloat
}

let fitScene = Fit(tx: -81.88, ty: -104.44, scale: 1.10059)
let fitMark = Fit(tx: -71.87, ty: -174.82, scale: 1.31148)
let fitMenuBar = Fit(tx: -121.05, ty: -239.44, scale: 1.50820)

func fillRoundedRect(_ c: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat) {
    let path = CGPath(
        roundedRect: CGRect(x: x, y: y, width: w, height: h),
        cornerWidth: min(r, w / 2),
        cornerHeight: min(r, h / 2),
        transform: nil
    )
    c.addPath(path)
    c.fillPath()
}

func setStroke(_ c: CGContext, width: CGFloat) {
    c.setLineWidth(width)
    c.setLineCap(.round)
    c.setLineJoin(.round)
}

// Seated figure: bent leg, hunched back curving into a forward-craned neck, dropped head.
func drawFigure(_ c: CGContext, bold: Bool) {
    setStroke(c, width: bold ? 58 : 42)
    c.move(to: CGPoint(x: 180, y: 360))
    c.addLine(to: CGPoint(x: 286, y: 372))
    c.addLine(to: CGPoint(x: 294, y: 452))
    c.strokePath()

    setStroke(c, width: bold ? 60 : 44)
    c.move(to: CGPoint(x: 180, y: 360))
    if bold {
        c.addCurve(
            to: CGPoint(x: 222, y: 232),
            control1: CGPoint(x: 156, y: 296),
            control2: CGPoint(x: 172, y: 242)
        )
        c.addCurve(
            to: CGPoint(x: 306, y: 242),
            control1: CGPoint(x: 258, y: 222),
            control2: CGPoint(x: 288, y: 230)
        )
    } else {
        c.addCurve(
            to: CGPoint(x: 220, y: 236),
            control1: CGPoint(x: 160, y: 300),
            control2: CGPoint(x: 172, y: 248)
        )
        c.addCurve(
            to: CGPoint(x: 300, y: 242),
            control1: CGPoint(x: 256, y: 226),
            control2: CGPoint(x: 282, y: 232)
        )
    }
    c.strokePath()

    let headRadius: CGFloat = bold ? 52 : 42
    let headCenter = bold ? CGPoint(x: 322, y: 228) : CGPoint(x: 314, y: 224)
    c.fillEllipse(in: CGRect(
        x: headCenter.x - headRadius,
        y: headCenter.y - headRadius,
        width: headRadius * 2,
        height: headRadius * 2
    ))
}

func drawDeskScene(_ c: CGContext) {
    fillRoundedRect(c, x: 300, y: 320, w: 176, h: 18, r: 9) // desk top
    fillRoundedRect(c, x: 428, y: 190, w: 28, h: 112, r: 11) // monitor screen
    fillRoundedRect(c, x: 437, y: 300, w: 10, h: 13, r: 0) // monitor stand
    fillRoundedRect(c, x: 420, y: 311, w: 46, h: 9, r: 4.5) // monitor base
    drawFigure(c, bold: false)
}

func drawArtwork(_ c: CGContext, _ artwork: Artwork, fit: Fit, pixels: Int, color: NSColor) {
    c.saveGState()
    c.translateBy(x: 0, y: CGFloat(pixels))
    c.scaleBy(x: CGFloat(pixels) / 512, y: -CGFloat(pixels) / 512)
    c.translateBy(x: fit.tx, y: fit.ty)
    c.scaleBy(x: fit.scale, y: fit.scale)
    c.setStrokeColor(color.cgColor)
    c.setFillColor(color.cgColor)
    switch artwork {
    case .markOnly:
        drawFigure(c, bold: true)
    case .deskScene:
        drawDeskScene(c)
    }
    c.restoreGState()
}

func render(pixels: Int, draw: (CGContext) -> Void) throws -> Data {
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
    draw(context)

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

func drawAppIcon(pixels: Int, pointSize: Int, context: CGContext) {
    let rect = CGRect(origin: .zero, size: CGSize(width: pixels, height: pixels))
    let radius = CGFloat(pixels) * 0.22
    let background = CGPath(
        roundedRect: rect.insetBy(dx: CGFloat(pixels) * 0.04, dy: CGFloat(pixels) * 0.04),
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
    context.setFillColor(teal.cgColor)
    context.addPath(background)
    context.fillPath()

    let artwork: Artwork = pointSize <= 32 ? .markOnly : .deskScene
    let fit = artwork == .markOnly ? fitMark : fitScene
    drawArtwork(context, artwork, fit: fit, pixels: pixels, color: .white)
}

try FileManager.default.createDirectory(at: appIconDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: menuBarDirectory, withIntermediateDirectories: true)

for variant in variants {
    let pixels = variant.size * variant.scale
    let data = try render(pixels: pixels) { context in
        drawAppIcon(pixels: pixels, pointSize: variant.size, context: context)
    }
    try data.write(to: appIconDirectory.appendingPathComponent(variant.filename), options: .atomic)
}

for variant in menuBarVariants {
    let pixels = variant.size * variant.scale
    let data = try render(pixels: pixels) { context in
        drawArtwork(context, .markOnly, fit: fitMenuBar, pixels: pixels, color: .black)
    }
    try data.write(to: menuBarDirectory.appendingPathComponent(variant.filename), options: .atomic)
}

print("Wrote \(variants.count) app icon files to \(appIconDirectory.path)")
print("Wrote \(menuBarVariants.count) menu bar icon files to \(menuBarDirectory.path)")
