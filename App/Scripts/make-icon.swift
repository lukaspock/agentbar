#!/usr/bin/env swift
// Generates Resources/Assets.xcassets/AppIcon.appiconset and Screenshots/icon-minimal.png.
// Usage (from the App directory): swift Scripts/make-icon.swift [variant 0-2, default = CHOSEN]
import AppKit

let CHOSEN = 0
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: a) }
struct Variant { let bg: NSColor; let blob: NSColor; let eye: NSColor }
let variants: [Variant] = [
    Variant(bg: .black, blob: .white, eye: col(0.08, 0.08, 0.09)),                       // pure black
    Variant(bg: col(0.110, 0.110, 0.118), blob: .white, eye: col(0.110, 0.110, 0.118)),  // #1c1c1e
]

func render(_ px: Int, _ v: Variant) -> NSBitmapImageRep {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let body = CGRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.025, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    v.bg.setFill(); squircle.fill()
    ctx.restoreGState()

    let d = body.width * 0.58
    let blob = CGRect(x: body.midX - d / 2, y: body.midY - d / 2, width: d, height: d)
    v.blob.setFill(); NSBezierPath(ovalIn: blob).fill()
    // Two plain pill eyes (as in the status blob), slightly below the centre
    let ew = d * 0.15, eh = d * 0.27
    v.eye.setFill()
    for dx in [-d * 0.15, d * 0.15] {
        NSBezierPath(roundedRect: CGRect(x: blob.midX + dx - ew / 2, y: blob.midY - eh / 2 - d * 0.05, width: ew, height: eh),
                     xRadius: ew / 2, yRadius: ew / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }
let fm = FileManager.default
let arg = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? CHOSEN : CHOSEN
let v = variants[arg]
let set = "Resources/Assets.xcassets/AppIcon.appiconset"
try fm.createDirectory(atPath: set, withIntermediateDirectories: true)
try Data("{\"info\":{\"version\":1,\"author\":\"xcode\"}}".utf8).write(to: URL(fileURLWithPath: "Resources/Assets.xcassets/Contents.json"))
var images: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)@\(scale)x.png"
        try png(render(base * scale, v)).write(to: URL(fileURLWithPath: "\(set)/\(name)"))
        images.append("{\"filename\":\"\(name)\",\"idiom\":\"mac\",\"scale\":\"\(scale)x\",\"size\":\"\(base)x\(base)\"}")
    }
}
try Data("{\"images\":[\(images.joined(separator: ","))],\"info\":{\"version\":1,\"author\":\"xcode\"}}".utf8)
    .write(to: URL(fileURLWithPath: "\(set)/Contents.json"))
// Preview: three 512 icons on light, 128/64/32 px on dark
let W = 2 * 540 + 20, H = 540 + 260
let pv = NSImage(size: NSSize(width: W, height: H))
pv.lockFocus()
NSColor(white: 0.90, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: 250).fill()
for (i, vv) in variants.enumerated() {
    let x = CGFloat(i * 540 + 20)
    NSImage(data: png(render(1024, vv)))!.draw(in: NSRect(x: x, y: 260, width: 520, height: 520))
    NSImage(data: png(render(128, vv)))!.draw(in: NSRect(x: x + 20, y: 100, width: 128, height: 128))
    NSImage(data: png(render(64, vv)))!.draw(in: NSRect(x: x + 180, y: 130, width: 64, height: 64))
    NSImage(data: png(render(32, vv)))!.draw(in: NSRect(x: x + 270, y: 146, width: 32, height: 32))
}
pv.unlockFocus()
try png(NSBitmapImageRep(data: pv.tiffRepresentation!)!).write(to: URL(fileURLWithPath: "Screenshots/icon-minimal.png"))
print("done variant \(arg)")
