// Fabrique l'icône macOS (carré arrondi, ombre légère) à partir de assets/logo.png.
// Usage : swift icon.swift assets/logo.png sortie.png
import AppKit
let args = CommandLine.arguments
guard let logo = NSImage(contentsOfFile: args[1]) else { fatalError("logo introuvable") }
let s = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
shape.addClip()
logo.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
NSColor.white.withAlphaComponent(0.08).setStroke()
shape.lineWidth = 3
shape.stroke()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
