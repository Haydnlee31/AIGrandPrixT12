import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Original vector bookmark mark; rendered locally without third-party artwork.
let output = CommandLine.arguments[1]
let bitmap = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let context = NSGraphicsContext(cgContext: bitmap, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
let mark = NSBezierPath()
mark.move(to: NSPoint(x: 325, y: 255))
mark.line(to: NSPoint(x: 325, y: 710))
mark.curve(to: NSPoint(x: 380, y: 765), controlPoint1: NSPoint(x: 325, y: 745), controlPoint2: NSPoint(x: 345, y: 765))
mark.line(to: NSPoint(x: 644, y: 765))
mark.curve(to: NSPoint(x: 699, y: 710), controlPoint1: NSPoint(x: 679, y: 765), controlPoint2: NSPoint(x: 699, y: 745))
mark.line(to: NSPoint(x: 699, y: 255))
mark.line(to: NSPoint(x: 512, y: 375))
mark.close()
NSColor.white.setFill(); mark.fill()
NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
for x in [442.0, 547.0] {
    NSBezierPath(roundedRect: NSRect(x: x, y: 583, width: 36, height: 18), xRadius: 9, yRadius: 9).fill()
}
NSGraphicsContext.restoreGraphicsState()
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write app icon") }
