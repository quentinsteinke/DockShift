import AppKit
// Usage: swift make-icon.swift <out.png>  — renders a 1024x1024 placeholder icon
let out = CommandLine.arguments[1]
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: CGFloat(size) - 2*inset, height: CGFloat(size) - 2*inset)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1), ending: NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.85, alpha: 1))!.draw(in: path, angle: -90)
NSColor.white.withAlphaComponent(0.9).setFill()
NSBezierPath(roundedRect: NSRect(x: 230, y: 230, width: 564, height: 120), xRadius: 40, yRadius: 40).fill()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
