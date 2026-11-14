// Draws the Macam app icon (a camera lens under a MacBook notch, with teleprompter lines) and writes a 1024px PNG.
// Usage: swift Tools/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }

/// Apple-style rounded square: a superellipse is closer to the system icon shape than a plain rounded rect.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 800
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let p = CGPoint(x: rect.midX + a * copysign(pow(abs(ct), 2 / n), ct), y: rect.midY + b * copysign(pow(abs(st), 2 / n), st))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = squircle(body)
let top = body.maxY

// 1. Soft drop shadow under the icon.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: color(0x000000, 0.5))
ctx.addPath(bodyPath); ctx.setFillColor(color(0x10121C)); ctx.fillPath()
ctx.restoreGState()

// 2. Body: deep ink gradient, a cool glow behind the lens, a sheen along the top edge.
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0x3A4064)), (0.5, color(0x1A1E33)), (1, color(0x0A0C15))]),
                       start: CGPoint(x: 512, y: top), end: CGPoint(x: 512, y: body.minY), options: [])
let lens = CGPoint(x: 512, y: 430)
ctx.drawRadialGradient(gradient([(0, color(0x5B6CFF, 0.34)), (1, color(0x5B6CFF, 0))]),
                       startCenter: lens, startRadius: 0, endCenter: lens, endRadius: 430, options: [])
ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.16)), (1, color(0xFFFFFF, 0))]),
                       start: CGPoint(x: 512, y: top), end: CGPoint(x: 512, y: top - 280), options: [])

// 3. The notch: a black tab hanging from the top edge, with the camera dot inside it.
let notchW: CGFloat = 310, notchH: CGFloat = 98, notchR: CGFloat = 46
let nx = 512 - notchW / 2
let notch = CGMutablePath()
notch.move(to: CGPoint(x: nx, y: top + 4))
notch.addLine(to: CGPoint(x: nx, y: top - notchH + notchR))
notch.addArc(tangent1End: CGPoint(x: nx, y: top - notchH), tangent2End: CGPoint(x: nx + notchR, y: top - notchH), radius: notchR)
notch.addLine(to: CGPoint(x: nx + notchW - notchR, y: top - notchH))
notch.addArc(tangent1End: CGPoint(x: nx + notchW, y: top - notchH), tangent2End: CGPoint(x: nx + notchW, y: top - notchH + notchR), radius: notchR)
notch.addLine(to: CGPoint(x: nx + notchW, y: top + 4))
notch.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.55))
ctx.addPath(notch); ctx.setFillColor(color(0x040509)); ctx.fillPath()
ctx.restoreGState()
let dot = CGPoint(x: 512, y: top - 50)
ctx.addPath(circle(dot, 15)); ctx.clip()
ctx.drawRadialGradient(gradient([(0, color(0x3D5BD9)), (1, color(0x0A1030))]), startCenter: CGPoint(x: dot.x - 4, y: dot.y + 4), startRadius: 0, endCenter: dot, endRadius: 15, options: [])
ctx.resetClip()
ctx.addPath(bodyPath); ctx.clip()
ctx.addPath(circle(CGPoint(x: dot.x - 5, y: dot.y + 5), 3)); ctx.setFillColor(color(0xFFFFFF, 0.9)); ctx.fillPath()

// 4. Two teleprompter lines under the notch: the first lit, the second waiting.
func line(_ y: CGFloat, _ w: CGFloat, _ c: CGColor, glow: Bool) {
    let r = CGRect(x: 512 - w / 2, y: y - 12, width: w, height: 24)
    ctx.saveGState()
    if glow { ctx.setShadow(offset: .zero, blur: 18, color: color(0xFFFFFF, 0.55)) }
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.setFillColor(c); ctx.fillPath()
    ctx.restoreGState()
}
line(top - 150, 340, color(0xFFFFFF, 0.96), glow: true)
line(top - 196, 220, color(0xFFFFFF, 0.38), glow: false)

// 5. The lens.
let R: CGFloat = 248
// bezel shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.6))
ctx.addPath(circle(lens, R)); ctx.setFillColor(color(0x0A0B12)); ctx.fillPath()
ctx.restoreGState()
// metal bezel
ctx.saveGState()
ctx.addPath(circle(lens, R)); ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0xFAFBFF)), (0.45, color(0xB6BBD0)), (1, color(0x6B7088))]),
                       start: CGPoint(x: lens.x - R, y: lens.y + R), end: CGPoint(x: lens.x + R, y: lens.y - R), options: [])
ctx.restoreGState()
// bezel inner lip
ctx.saveGState()
ctx.addPath(circle(lens, R - 20)); ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0x2A2E44)), (1, color(0x0B0C14))]),
                       start: CGPoint(x: lens.x - R, y: lens.y + R), end: CGPoint(x: lens.x + R, y: lens.y - R), options: [])
ctx.restoreGState()
// glass
ctx.saveGState()
ctx.addPath(circle(lens, R - 34)); ctx.clip()
ctx.drawRadialGradient(gradient([(0, color(0x1E2747)), (0.6, color(0x0C1020)), (1, color(0x05060C))]),
                       startCenter: CGPoint(x: lens.x - 40, y: lens.y + 50), startRadius: 0, endCenter: lens, endRadius: R - 34, options: [.drawsAfterEndLocation])
// faint lens-group rings
for (r, a) in [(CGFloat(196), CGFloat(0.07)), (CGFloat(170), CGFloat(0.05))] {
    ctx.addPath(circle(lens, r)); ctx.setStrokeColor(color(0xFFFFFF, a)); ctx.setLineWidth(3); ctx.strokePath()
}
ctx.restoreGState()
// iris ring with a blue-to-violet glow
let ring = CGMutablePath()
ring.addPath(circle(lens, 152)); ring.addPath(circle(lens, 116))
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 34, color: color(0x7A6CFF, 0.75))
ctx.addPath(ring); ctx.clip(using: .evenOdd)
ctx.drawLinearGradient(gradient([(0, color(0x62D2FF)), (0.5, color(0x6C86FF)), (1, color(0xB05CFF))]),
                       start: CGPoint(x: lens.x - 150, y: lens.y + 150), end: CGPoint(x: lens.x + 150, y: lens.y - 150), options: [])
ctx.restoreGState()
// pupil
ctx.saveGState()
ctx.addPath(circle(lens, 100)); ctx.clip()
ctx.drawRadialGradient(gradient([(0, color(0x0D1226)), (1, color(0x04050A))]),
                       startCenter: CGPoint(x: lens.x - 20, y: lens.y + 20), startRadius: 0, endCenter: lens, endRadius: 100, options: [])
ctx.restoreGState()
// reflections
ctx.saveGState()
ctx.addPath(circle(lens, R - 34)); ctx.clip()
// A curved highlight hugging the upper-left edge of the glass.
let arc = CGMutablePath()
arc.addArc(center: lens, radius: R - 52, startAngle: 112 * .pi / 180, endAngle: 168 * .pi / 180, clockwise: false)
let arcStroke = arc.copy(strokingWithWidth: 13, lineCap: .round, lineJoin: .round, miterLimit: 10)
ctx.addPath(arcStroke); ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.55)), (1, color(0xFFFFFF, 0.05))]),
                       start: CGPoint(x: lens.x - 60, y: lens.y + 190), end: CGPoint(x: lens.x - 190, y: lens.y + 40), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 10, color: color(0xFFFFFF, 0.8))
ctx.addPath(circle(CGPoint(x: lens.x - 62, y: lens.y + 70), 20)); ctx.setFillColor(color(0xFFFFFF, 0.92)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(circle(CGPoint(x: lens.x + 66, y: lens.y - 62), 8)); ctx.setFillColor(color(0xFFFFFF, 0.4)); ctx.fillPath()

// 6. A small red recording light, top right.
let rec = CGPoint(x: 796, y: top - 78)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 26, color: color(0xFF3B4D, 0.9))
ctx.addPath(circle(rec, 21)); ctx.setFillColor(color(0xFF4A5A)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(circle(CGPoint(x: rec.x - 6, y: rec.y + 7), 6)); ctx.setFillColor(color(0xFFFFFF, 0.55)); ctx.fillPath()

ctx.resetClip()
ctx.restoreGState()   // body clip

// 7. Fine inner edge so the icon reads on any background.
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.addPath(bodyPath); ctx.setStrokeColor(color(0xFFFFFF, 0.14)); ctx.setLineWidth(5); ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { exit(1) }
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
