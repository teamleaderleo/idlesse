// Regenerate the canonical 1024px Idlesse icon.
// Usage: swift scripts/generate-icon.swift Assets/Idlesse.png

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/Idlesse.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: size * 4, space: colorSpace,
                    bitmapInfo: info)!
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

let canvas = CGRect(x: 0, y: 0, width: size, height: size)
ctx.clear(canvas)
// Draw in a conventional top-left design coordinate system.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func fillPath(_ path: CGPath, _ fill: CGColor) {
    ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
}
func strokePath(_ path: CGPath, _ stroke: CGColor, _ width: CGFloat) {
    ctx.addPath(path); ctx.setStrokeColor(stroke); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
}

let tile = rounded(CGRect(x: 48, y: 48, width: 928, height: 928), 232)
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let bgStops: [CGFloat] = [0, 0.52, 1]
let bgColors = [
    color(0.055, 0.08, 0.20),
    color(0.10, 0.13, 0.32),
    color(0.17, 0.10, 0.30)
] as CFArray
let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgStops)!
ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 512, y: 976), end: CGPoint(x: 512, y: 48), options: [])

// A quiet lower glow gives the tile depth without introducing another symbol.
let glowColors = [color(0.27, 0.14, 0.46, 0.30), color(0.27, 0.14, 0.46, 0.0)] as CFArray
let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0, 1])!
ctx.drawRadialGradient(glowGradient, startCenter: CGPoint(x: 512, y: 375), startRadius: 20,
                       endCenter: CGPoint(x: 512, y: 375), endRadius: 510, options: [])
ctx.restoreGState()

// Frosted wallpaper window: one supporting frame, kept quiet behind the cat.
let windowPath = rounded(CGRect(x: 162, y: 152, width: 700, height: 720), 116)
fillPath(windowPath, color(0.025, 0.04, 0.12, 0.48))
strokePath(windowPath, color(0.35, 0.86, 0.98, 0.38), 10)
let innerPath = rounded(CGRect(x: 184, y: 174, width: 656, height: 676), 94)
strokePath(innerPath, color(0.73, 0.91, 1.0, 0.10), 3)

// Subtle window header line, deliberately not a set of dots or a second icon.
let header = CGMutablePath(); header.move(to: CGPoint(x: 236, y: 260)); header.addLine(to: CGPoint(x: 788, y: 260))
strokePath(header, color(0.47, 0.79, 0.95, 0.18), 5)

// Cat silhouette with two explicit ears and no tail: unmistakable at small sizes.
let cat = CGMutablePath()
cat.move(to: CGPoint(x: 290, y: 642))
cat.addCurve(to: CGPoint(x: 291, y: 485), control1: CGPoint(x: 286, y: 582), control2: CGPoint(x: 288, y: 520))
cat.addCurve(to: CGPoint(x: 336, y: 355), control1: CGPoint(x: 298, y: 438), control2: CGPoint(x: 310, y: 388))
cat.addLine(to: CGPoint(x: 387, y: 216))
cat.addLine(to: CGPoint(x: 468, y: 319))
cat.addCurve(to: CGPoint(x: 512, y: 312), control1: CGPoint(x: 486, y: 309), control2: CGPoint(x: 497, y: 312))
cat.addCurve(to: CGPoint(x: 556, y: 319), control1: CGPoint(x: 527, y: 312), control2: CGPoint(x: 540, y: 309))
cat.addLine(to: CGPoint(x: 637, y: 216))
cat.addLine(to: CGPoint(x: 688, y: 355))
cat.addCurve(to: CGPoint(x: 733, y: 485), control1: CGPoint(x: 713, y: 388), control2: CGPoint(x: 726, y: 438))
cat.addCurve(to: CGPoint(x: 734, y: 642), control1: CGPoint(x: 736, y: 520), control2: CGPoint(x: 738, y: 582))
cat.addCurve(to: CGPoint(x: 662, y: 738), control1: CGPoint(x: 719, y: 684), control2: CGPoint(x: 690, y: 720))
cat.addCurve(to: CGPoint(x: 512, y: 782), control1: CGPoint(x: 625, y: 772), control2: CGPoint(x: 564, y: 785))
cat.addCurve(to: CGPoint(x: 362, y: 738), control1: CGPoint(x: 460, y: 785), control2: CGPoint(x: 399, y: 772))
cat.addCurve(to: CGPoint(x: 290, y: 642), control1: CGPoint(x: 332, y: 720), control2: CGPoint(x: 305, y: 684))
cat.closeSubpath()

// Soft silhouette shadow.
ctx.saveGState()
ctx.translateBy(x: 0, y: 18)
fillPath(cat, color(0.015, 0.02, 0.07, 0.62))
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(cat); ctx.clip()
let catColors = [color(1.0, 0.82, 0.60), color(0.95, 0.58, 0.63), color(0.77, 0.61, 0.98)] as CFArray
let catGradient = CGGradient(colorsSpace: colorSpace, colors: catColors, locations: [0, 0.52, 1])!
ctx.drawLinearGradient(catGradient, start: CGPoint(x: 390, y: 180), end: CGPoint(x: 650, y: 800), options: [])
ctx.restoreGState()

// Closed eyes; the only facial detail, so the mark stays calm and legible.
let leftEye = CGMutablePath(); leftEye.move(to: CGPoint(x: 379, y: 548)); leftEye.addCurve(to: CGPoint(x: 430, y: 566), control1: CGPoint(x: 396, y: 566), control2: CGPoint(x: 414, y: 566))
let rightEye = CGMutablePath(); rightEye.move(to: CGPoint(x: 594, y: 548)); rightEye.addCurve(to: CGPoint(x: 645, y: 548), control1: CGPoint(x: 611, y: 566), control2: CGPoint(x: 629, y: 566))
strokePath(leftEye, color(0.16, 0.09, 0.24, 0.86), 13)
strokePath(rightEye, color(0.16, 0.09, 0.24, 0.86), 13)

// Tiny single four-point glint: one ambient accent, not a moon or duplicate celestial object.
let sparkle = CGMutablePath()
sparkle.move(to: CGPoint(x: 764, y: 330)); sparkle.addLine(to: CGPoint(x: 775, y: 360)); sparkle.addLine(to: CGPoint(x: 804, y: 371)); sparkle.addLine(to: CGPoint(x: 775, y: 382)); sparkle.addLine(to: CGPoint(x: 764, y: 412)); sparkle.addLine(to: CGPoint(x: 753, y: 382)); sparkle.addLine(to: CGPoint(x: 724, y: 371)); sparkle.addLine(to: CGPoint(x: 753, y: 360)); sparkle.closeSubpath()
fillPath(sparkle, color(0.83, 0.96, 1.0, 0.88))

// Clip a mild highlight to the tile edge.
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let sheen = CGMutablePath(); sheen.move(to: CGPoint(x: 178, y: 122)); sheen.addCurve(to: CGPoint(x: 810, y: 90), control1: CGPoint(x: 406, y: 12), control2: CGPoint(x: 677, y: 18))
strokePath(sheen, color(0.75, 0.90, 1.0, 0.16), 10)
ctx.restoreGState()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: output)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
precondition(CGImageDestinationFinalize(destination), "Unable to write PNG")
print(output)
