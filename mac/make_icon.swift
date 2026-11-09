// Draws the D-Log Tagger app icon (1024x1024 PNG).
// Usage: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let orange = rgb(255, 149, 0), blue = rgb(10, 132, 255)

// macOS icon grid: 824pt body centred in 1024, ~185pt corner radius
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// soft drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(shape); ctx.setFillColor(rgb(30, 30, 34)); ctx.fillPath()
ctx.restoreGState()

// background gradient
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: nil, colors: [rgb(52, 54, 62), rgb(18, 18, 22)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// scope-style graph area
let plot = CGRect(x: 210, y: 300, width: 604, height: 500)
ctx.setStrokeColor(rgb(255, 255, 255, 0.07)); ctx.setLineWidth(4)
for i in 0...4 {
    let x = plot.minX + plot.width * CGFloat(i) / 4
    let y = plot.minY + plot.height * CGFloat(i) / 4
    ctx.move(to: CGPoint(x: x, y: plot.minY)); ctx.addLine(to: CGPoint(x: x, y: plot.maxY))
    ctx.move(to: CGPoint(x: plot.minX, y: y)); ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
}
ctx.strokePath()

// two log curves: lifted blacks, rolled-off highlights
func logCurve(lift: CGFloat, gain: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0...120 {
        let t = CGFloat(i) / 120
        let v = lift + (1 - lift) * log(1 + gain * t) / log(1 + gain)
        let pt = CGPoint(x: plot.minX + plot.width * t, y: plot.minY + plot.height * v * 0.92)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    return p
}
func stroke(_ path: CGPath, _ color: CGColor) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color)
    ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(30)
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
    ctx.restoreGState()
}
stroke(logCurve(lift: 0.06, gain: 9), blue)
stroke(logCurve(lift: 0.18, gain: 30), orange)

// "LOG" label
let para = NSMutableParagraphStyle(); para.alignment = .center
let font = NSFont.systemFont(ofSize: 132, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.92),
    .kern: 14, .paragraphStyle: para,
]
NSAttributedString(string: "LOG", attributes: attrs)
    .draw(in: CGRect(x: 100, y: 140, width: 824, height: 160))

// subtle top highlight
let hl = CGGradient(colorsSpace: nil, colors: [rgb(255, 255, 255, 0.10), rgb(255, 255, 255, 0)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

// thin rim
ctx.addPath(shape); ctx.setStrokeColor(rgb(255, 255, 255, 0.12)); ctx.setLineWidth(3); ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
