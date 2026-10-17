// Regenerate the canonical 1024px Idlesse icon.
// Usage: swift scripts/generate-icon.swift Assets/Idlesse.png

import AppKit
import CoreGraphics

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
let imageContext = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = imageContext
let c = imageContext.cgContext
c.setAllowsAntialiasing(true)
c.interpolationQuality = CGInterpolationQuality.high

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func fillPath(_ path: CGPath, _ fill: CGColor) {
    c.addPath(path); c.setFillColor(fill); c.fillPath()
}
func fillEvenOdd(_ path: CGPath, _ fill: CGColor) {
    c.addPath(path); c.setFillColor(fill); c.fillPath(using: .evenOdd)
}
func strokePath(_ path: CGPath, _ stroke: CGColor, _ width: CGFloat) {
    c.addPath(path); c.setStrokeColor(stroke); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round); c.strokePath()
}
func linearGradient(_ rect: CGRect, _ colors: [CGColor], _ locations: [CGFloat]) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)!
    c.saveGState(); c.addPath(roundedRect(rect, 220)); c.clip()
    c.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    c.restoreGState()
}

let canvas = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
c.setFillColor(color(0.035, 0.027, 0.075, 1)); c.fill(canvas)
let tile = CGRect(x: 48, y: 48, width: 928, height: 928)
linearGradient(tile, [color(0.20,0.10,0.40), color(0.055,0.075,0.20)], [0,1])

// Ambient glow behind the scene.
c.saveGState(); c.setShadow(offset: .zero, blur: 70, color: color(0.33,0.68,1,0.36))
fillPath(CGPath(ellipseIn: CGRect(x: 220, y: 300, width: 590, height: 480), transform: nil), color(0.18,0.34,0.70,0.25)); c.restoreGState()

// A translucent wallpaper window gives the mark its desktop identity.
let window = CGRect(x: 152, y: 168, width: 720, height: 460)
c.saveGState(); c.addPath(roundedRect(window, 64)); c.clip()
let windowGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0.34,0.69,0.92,0.27), color(0.30,0.17,0.63,0.10)] as CFArray, locations: [0,1])!
c.drawLinearGradient(windowGradient, start: CGPoint(x: window.minX, y: window.maxY), end: CGPoint(x: window.maxX, y: window.minY), options: [])
c.restoreGState()
strokePath(roundedRect(window, 64), color(0.77,0.89,1,0.28), 4)
// Window controls.
for x in [208.0, 244.0, 280.0] { fillPath(CGPath(ellipseIn: CGRect(x: x, y: 560, width: 14, height: 14), transform: nil), color(0.87,0.95,1,0.48)) }

// Crescent moon, with an even-odd cutout.
var crescent = CGMutablePath()
crescent.addEllipse(in: CGRect(x: 226, y: 126, width: 626, height: 626))
crescent.addEllipse(in: CGRect(x: 390, y: 244, width: 552, height: 552))
fillEvenOdd(crescent, color(0.98,0.93,0.82,1))
// Warm rim and shadow.
strokePath(CGPath(ellipseIn: CGRect(x: 226, y: 126, width: 626, height: 626), transform: nil), color(1,0.96,0.88,0.38), 7)

// Sleeping cat silhouette.
let fur = color(0.98,0.93,0.84,1)
let furShadow = color(0.78,0.62,0.76,0.42)
// Compact body tucked into the crescent.
fillPath(CGPath(ellipseIn: CGRect(x: 392, y: 278, width: 286, height: 206), transform: nil), fur)
// Tail curls upward behind the body.
var tail = CGMutablePath(); tail.move(to: CGPoint(x: 610, y: 360)); tail.addCurve(to: CGPoint(x: 760, y: 326), control1: CGPoint(x: 682, y: 308), control2: CGPoint(x: 724, y: 250)); tail.addCurve(to: CGPoint(x: 790, y: 430), control1: CGPoint(x: 810, y: 352), control2: CGPoint(x: 806, y: 400)); tail.addCurve(to: CGPoint(x: 738, y: 494), control1: CGPoint(x: 782, y: 452), control2: CGPoint(x: 760, y: 482)); strokePath(tail, fur, 40)
// Head and two clean ears.
var head = CGMutablePath()
head.move(to: CGPoint(x: 284, y: 474))
head.addCurve(to: CGPoint(x: 292, y: 380), control1: CGPoint(x: 270, y: 440), control2: CGPoint(x: 272, y: 404))
head.addLine(to: CGPoint(x: 350, y: 430))
head.addLine(to: CGPoint(x: 414, y: 352))
head.addLine(to: CGPoint(x: 468, y: 426))
head.addCurve(to: CGPoint(x: 560, y: 492), control1: CGPoint(x: 530, y: 402), control2: CGPoint(x: 574, y: 438))
head.addCurve(to: CGPoint(x: 284, y: 474), control1: CGPoint(x: 548, y: 606), control2: CGPoint(x: 292, y: 602))
head.closeSubpath(); fillPath(head, fur)
var leftEar = CGMutablePath(); leftEar.move(to: CGPoint(x: 300,y:455)); leftEar.addLine(to: CGPoint(x:326,y:408)); leftEar.addLine(to: CGPoint(x:360,y:440)); leftEar.closeSubpath(); fillPath(leftEar, furShadow)
var rightEar = CGMutablePath(); rightEar.move(to: CGPoint(x:414,y:414)); rightEar.addLine(to: CGPoint(x:426,y:378)); rightEar.addLine(to: CGPoint(x:454,y:424)); rightEar.closeSubpath(); fillPath(rightEar, furShadow)
// Paws resting on the moon.
fillPath(CGPath(ellipseIn: CGRect(x: 390, y: 248, width: 98, height: 66), transform: nil), fur)
fillPath(CGPath(ellipseIn: CGRect(x: 482, y: 244, width: 98, height: 70), transform: nil), fur)
// Face: relaxed eyes, nose and whiskers.
var eye1 = CGMutablePath(); eye1.move(to: CGPoint(x: 342,y:470)); eye1.addCurve(to: CGPoint(x: 382,y:458), control1: CGPoint(x: 354,y: 486), control2: CGPoint(x: 372,y: 484)); strokePath(eye1, color(0.20,0.10,0.30,0.95), 11)
var eye2 = CGMutablePath(); eye2.move(to: CGPoint(x: 444,y:458)); eye2.addCurve(to: CGPoint(x: 484,y:470), control1: CGPoint(x: 454,y: 484), control2: CGPoint(x: 474,y: 486)); strokePath(eye2, color(0.20,0.10,0.30,0.95), 11)
fillPath(CGPath(ellipseIn: CGRect(x: 406, y: 430, width: 24, height: 18), transform: nil), color(0.78,0.25,0.48,1))
var smile = CGMutablePath(); smile.move(to: CGPoint(x: 418,y:430)); smile.addCurve(to: CGPoint(x: 418,y:412), control1: CGPoint(x: 414,y:420), control2: CGPoint(x: 414,y:416)); smile.addCurve(to: CGPoint(x: 434,y:412), control1: CGPoint(x: 424,y:416), control2: CGPoint(x: 428,y:416)); strokePath(smile, color(0.20,0.10,0.30,0.85), 6)
for y in [426.0, 444.0] {
    let whisker = CGMutablePath(); whisker.move(to: CGPoint(x: 340,y: y)); whisker.addLine(to: CGPoint(x: 288,y: y + (y == 426 ? 8 : -3))); strokePath(whisker, color(0.53,0.38,0.55,0.72), 5)
    let whiskerR = CGMutablePath(); whiskerR.move(to: CGPoint(x: 486,y: y)); whiskerR.addLine(to: CGPoint(x: 538,y: y + (y == 426 ? -3 : 8))); strokePath(whiskerR, color(0.53,0.38,0.55,0.72), 5)
}

// Four-point ambient sparkle.
var sparkle = CGMutablePath(); sparkle.move(to: CGPoint(x: 770,y:760)); sparkle.addLine(to: CGPoint(x: 786,y:806)); sparkle.addLine(to: CGPoint(x: 832,y:822)); sparkle.addLine(to: CGPoint(x: 786,y:838)); sparkle.addLine(to: CGPoint(x:770,y:884)); sparkle.addLine(to: CGPoint(x:754,y:838)); sparkle.addLine(to: CGPoint(x:708,y:822)); sparkle.addLine(to: CGPoint(x:754,y:806)); sparkle.closeSubpath(); fillPath(sparkle, color(0.55,0.88,1,0.95))

// Subtle inner highlight to keep the icon legible at small sizes.
strokePath(roundedRect(tile.insetBy(dx: 6, dy: 6), 214), color(0.88,0.85,1,0.18), 4)

let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
