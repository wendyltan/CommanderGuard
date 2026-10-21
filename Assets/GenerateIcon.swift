// Run from the repository root: swift Assets/GenerateIcon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = root.appendingPathComponent("build/CommanderGuard.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func brandMark(in rect: NSRect, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: rect.minX, y: rect.minY)
    context.scaleBy(x: rect.width / 128, y: rect.height / 128)
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 64, y: 9))
    shield.curve(to: NSPoint(x: 109, y: 26), controlPoint1: NSPoint(x: 77, y: 18), controlPoint2: NSPoint(x: 93, y: 23))
    shield.line(to: NSPoint(x: 109, y: 58))
    shield.curve(to: NSPoint(x: 64, y: 119), controlPoint1: NSPoint(x: 109, y: 86), controlPoint2: NSPoint(x: 93, y: 106))
    shield.curve(to: NSPoint(x: 19, y: 58), controlPoint1: NSPoint(x: 35, y: 106), controlPoint2: NSPoint(x: 19, y: 86))
    shield.line(to: NSPoint(x: 19, y: 26))
    shield.curve(to: NSPoint(x: 64, y: 9), controlPoint1: NSPoint(x: 35, y: 23), controlPoint2: NSPoint(x: 51, y: 18))
    shield.close()
    shield.lineWidth = 8; shield.lineJoinStyle = .round
    color.setStroke(); shield.stroke()
    let prompt = NSBezierPath()
    prompt.move(to: NSPoint(x: 44, y: 47)); prompt.line(to: NSPoint(x: 60, y: 62)); prompt.line(to: NSPoint(x: 44, y: 77))
    prompt.move(to: NSPoint(x: 75, y: 78)); prompt.line(to: NSPoint(x: 88, y: 78))
    prompt.lineWidth = 8; prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round
    prompt.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

final class MarkView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { brandMark(in: bounds, color: .black) }
}
let mark = MarkView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
try mark.dataWithPDF(inside: mark.bounds).write(to: assets.appendingPathComponent("BrandMark.pdf"))

func iconPNG(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.translateBy(x: 0, y: CGFloat(pixels)); context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196)
    NSColor(srgbRed: 246 / 255, green: 248 / 255, blue: 251 / 255, alpha: 1).setFill(); tile.fill()
    NSColor(srgbRed: 227 / 255, green: 231 / 255, blue: 237 / 255, alpha: 1).setStroke()
    tile.lineWidth = 2; tile.stroke()
    brandMark(in: NSRect(x: 196, y: 180, width: 632, height: 632), color: NSColor(srgbRed: 22 / 255, green: 105 / 255, blue: 211 / 255, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    precondition(bitmap.pixelsWide == pixels && bitmap.pixelsHigh == pixels)
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try iconPNG(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try iconPNG(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try iconPNG(pixels: 1024).write(to: assets.appendingPathComponent("AppIcon.png"))
let iconutil = Process(); iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit(); precondition(iconutil.terminationStatus == 0)
let vector = NSImage(contentsOf: assets.appendingPathComponent("BrandMark.pdf"))!
precondition(vector.representations.contains { $0 is NSPDFImageRep })
print("Generated AppIcon.png, AppIcon.icns and vector BrandMark.pdf")
