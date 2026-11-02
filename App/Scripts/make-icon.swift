#!/usr/bin/env swift
// Generates Resources/Assets.xcassets/AppIcon.appiconset (+ Screenshots/icon-preview.png).
// Usage: swift Scripts/make-icon.swift   (run from the App directory)
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true); ctx.interpolationQuality = .high
    // macOS icon grid: 824/1024 squircle with transparent margin.
    let body = CGRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); squircle.fill()
    ctx.restoreGState()
    // Background gradient (dark, notch-like, slight indigo)
    ctx.saveGState(); squircle.addClip()
    let bg = NSGradient(colors: [NSColor(red: 0.20, green: 0.21, blue: 0.30, alpha: 1), NSColor(red: 0.07, green: 0.07, blue: 0.11, alpha: 1)])!
    bg.draw(in: body, angle: -90)
    // Blob
    let d = body.width * 0.60
    let blob = CGRect(x: body.midX - d / 2, y: body.midY - d / 2 - body.height * 0.01, width: d, height: d)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.07, color: NSColor(red: 0.45, green: 0.85, blue: 0.70, alpha: 0.55).cgColor)
    let blobPath = NSBezierPath(ovalIn: blob)
    NSGradient(colors: [NSColor(red: 0.62, green: 0.95, blue: 0.80, alpha: 1), NSColor(red: 0.36, green: 0.78, blue: 0.62, alpha: 1)])!
        .draw(in: blobPath, angle: -90)
    ctx.restoreGState()
    // Highlight
    ctx.saveGState(); blobPath.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: blob.minX, y: blob.midY, width: blob.width, height: blob.height / 2), angle: -90)
    ctx.restoreGState()
    // Eyes (pill capsules like the status blob)
    let ew = d * 0.14, eh = d * 0.27
    for dx in [-d * 0.17, d * 0.17] {
        let r = CGRect(x: blob.midX + dx - ew / 2, y: blob.midY - eh / 2 + d * 0.03, width: ew, height: eh)
        NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: ew / 2, yRadius: ew / 2).fill()
    }
    // Cheeks
    NSColor(red: 1.0, green: 0.68, blue: 0.55, alpha: 0.55).setFill()
    for dx in [-d * 0.31, d * 0.31] {
        NSBezierPath(ovalIn: CGRect(x: blob.midX + dx - d * 0.06, y: blob.midY - d * 0.15, width: d * 0.12, height: d * 0.075)).fill()
    }
    ctx.restoreGState()
    // Subtle rim
    NSColor.white.withAlphaComponent(0.10).setStroke(); squircle.lineWidth = max(1, s * 0.004); squircle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = "Resources/Assets.xcassets/AppIcon.appiconset"
try fm.createDirectory(atPath: set, withIntermediateDirectories: true)
try Data("{\"info\":{\"version\":1,\"author\":\"xcode\"}}".utf8).write(to: URL(fileURLWithPath: "Resources/Assets.xcassets/Contents.json"))
var images: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)@\(scale)x.png"
        try render(base * scale).write(to: URL(fileURLWithPath: "\(set)/\(name)"))
        images.append("{\"filename\":\"\(name)\",\"idiom\":\"mac\",\"scale\":\"\(scale)x\",\"size\":\"\(base)x\(base)\"}")
    }
}
try Data("{\"images\":[\(images.joined(separator: ","))],\"info\":{\"version\":1,\"author\":\"xcode\"}}".utf8)
    .write(to: URL(fileURLWithPath: "\(set)/Contents.json"))
// Preview: 1024 + 128 + 32 on light gray
let pv = NSImage(size: NSSize(width: 1300, height: 1024))
pv.lockFocus()
NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1300, height: 1024).fill()
for (px, x, y) in [(1024, 0, 0), (128, 1040, 800), (64, 1040, 700), (32, 1040, 640)] {
    NSImage(data: render(px))!.draw(in: NSRect(x: x, y: y, width: px, height: px))
}
pv.unlockFocus()
let t = NSBitmapImageRep(data: pv.tiffRepresentation!)!
try t.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Screenshots/icon-preview.png"))
print("done")
