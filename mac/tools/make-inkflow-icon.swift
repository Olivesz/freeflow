import AppKit

func gray(_ v: CGFloat,_ a: CGFloat = 1) -> CGColor { NSColor(white: v, alpha: a).cgColor }
func squircle(in r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath(); let a = r.width/2, b = r.height/2, cx = r.midX, cy = r.midY
    for i in 0...720 { let t = CGFloat(i)/720*2 * .pi, ct = cos(t), st = sin(t)
        let x = cx+a*copysign(pow(abs(ct),2/n),ct), y = cy+b*copysign(pow(abs(st),2/n),st)
        i==0 ? p.move(to: .init(x:x,y:y)) : p.addLine(to: .init(x:x,y:y)) }
    p.closeSubpath(); return p
}

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
let S = CGFloat(px), cs = CGColorSpaceCreateDeviceRGB()
let inset = S*0.09
let rect = CGRect(x: inset, y: inset+S*0.012, width: S-2*inset, height: S-2*inset)
let shape = squircle(in: rect)
let W = rect.width, cx = rect.midX

// drop shadow tile
ctx.saveGState(); ctx.addPath(shape)
ctx.setShadow(offset: .init(width: 0, height: -S*0.015), blur: S*0.055, color: gray(0,0.4))
ctx.setFillColor(gray(1)); ctx.fillPath(); ctx.restoreGState()

ctx.saveGState(); ctx.addPath(shape); ctx.clip()

// night sky: deep charcoal, slightly lighter near the horizon
let bg = CGGradient(colorsSpace: cs, colors: [gray(0.09), gray(0.05), gray(0.13)] as CFArray, locations: [0,0.55,1])!
ctx.drawLinearGradient(bg, start: .init(x: cx, y: rect.maxY), end: .init(x: cx, y: rect.minY), options: [])

let horizon = rect.minY + rect.height*0.46

// moon: soft luminous disc above the horizon
let moon = CGPoint(x: cx + W*0.14, y: rect.minY + rect.height*0.72)
let mR = W*0.13
ctx.saveGState()
let halo = CGGradient(colorsSpace: cs, colors: [gray(1,0.35), gray(1,0)] as CFArray, locations: [0,1])!
ctx.drawRadialGradient(halo, startCenter: moon, startRadius: 0, endCenter: moon, endRadius: mR*2.6, options: [])
ctx.setFillColor(gray(0.96))
ctx.fillEllipse(in: CGRect(x: moon.x-mR, y: moon.y-mR, width: 2*mR, height: 2*mR))
// subtle shading on the moon
ctx.addEllipse(in: CGRect(x: moon.x-mR, y: moon.y-mR, width: 2*mR, height: 2*mR)); ctx.clip()
let ms = CGGradient(colorsSpace: cs, colors: [gray(0.12,0), gray(0.12,0.5)] as CFArray, locations: [0.4,1])!
ctx.drawRadialGradient(ms, startCenter: .init(x: moon.x+mR*0.3, y: moon.y-mR*0.3), startRadius: 0, endCenter: .init(x: moon.x+mR*0.3, y: moon.y-mR*0.3), endRadius: mR*1.6, options: [])
ctx.restoreGState()

// ---- flow field of flowing ink lines (the river) ----
func angle(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
    let nx = (x-cx)/W, ny = (y-horizon)/W
    return 0.55*sin(nx*3.1 + ny*1.2) + 0.35*sin(nx*1.4 - ny*3.4 + 1.1) + 0.18*sin(ny*6.0 + 2.0)
}
func streamlines(yTop: CGFloat, yBot: CGFloat, dx: CGFloat, dy: CGFloat, len: Int, step: CGFloat,
                 wMin: CGFloat, wMax: CGFloat, aMin: CGFloat, aMax: CGFloat, seed0: UInt64) {
    var seed = seed0
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed>>33)&0xFFFFFF)/CGFloat(0xFFFFFF) }
    var sy = yBot
    while sy <= yTop {
        var sx = rect.minX - W*0.1
        while sx <= rect.maxX + W*0.1 {
            var p = CGPoint(x: sx + rnd()*dx, y: sy + (rnd()-0.5)*dy)
            let path = CGMutablePath(); path.move(to: p)
            for _ in 0..<len {
                let a = angle(p.x, p.y)
                p = CGPoint(x: p.x + cos(a)*step, y: p.y + sin(a)*step)
                path.addLine(to: p)
            }
            ctx.addPath(path)
            ctx.setStrokeColor(gray(1, aMin + rnd()*(aMax-aMin)))
            ctx.setLineWidth(wMin + rnd()*(wMax-wMin)); ctx.setLineCap(.round)
            ctx.strokePath()
            sx += dx
        }
        sy += dy
    }
}
// water: dense, brighter, below horizon
streamlines(yTop: horizon + W*0.02, yBot: rect.minY - W*0.05, dx: W*0.02, dy: W*0.018,
            len: 70, step: W*0.012, wMin: S*0.0009, wMax: S*0.0022, aMin: 0.10, aMax: 0.42, seed0: 12345)
// mist/wind: sparse, faint, above horizon
streamlines(yTop: rect.maxY + W*0.05, yBot: horizon, dx: W*0.05, dy: W*0.05,
            len: 55, step: W*0.012, wMin: S*0.0008, wMax: S*0.0016, aMin: 0.04, aMax: 0.16, seed0: 99)

// willow: fine strands draping from a branch along the top-left, swaying down
ctx.saveGState()
var wseed: UInt64 = 555
func wr() -> CGFloat { wseed = wseed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((wseed>>33)&0xFFFFFF)/CGFloat(0xFFFFFF) }
for i in 0..<40 {
    let t = CGFloat(i)/39
    let anchor = CGPoint(x: rect.minX + W*(0.04 + t*0.34), y: rect.maxY - W*0.015 - wr()*W*0.04)
    let drift = W*(0.05 + t*0.14) + (wr()-0.5)*W*0.05    // strands drift outward as branch extends
    let len = W*(0.30 + wr()*0.55)
    let end = CGPoint(x: anchor.x + drift, y: anchor.y - len)
    let path = CGMutablePath(); path.move(to: anchor)
    path.addCurve(to: end,
                  control1: .init(x: anchor.x + drift*0.1, y: anchor.y - len*0.45),
                  control2: .init(x: anchor.x + drift*1.15, y: anchor.y - len*0.8))
    ctx.addPath(path); ctx.setStrokeColor(gray(1, 0.09 + wr()*0.20)); ctx.setLineWidth(S*0.0010); ctx.setLineCap(.round); ctx.strokePath()
}
ctx.restoreGState()

// ink-wash mist band near horizon for depth
let mist = CGGradient(colorsSpace: cs, colors: [gray(1,0), gray(1,0.06), gray(1,0)] as CFArray, locations: [0,0.5,1])!
ctx.drawLinearGradient(mist, start: .init(x: cx, y: horizon + W*0.12), end: .init(x: cx, y: horizon - W*0.12), options: [])

// vignette
ctx.setBlendMode(.multiply)
ctx.drawRadialGradient(CGGradient(colorsSpace: cs, colors: [gray(0,0), gray(0,0.5)] as CFArray, locations: [0.5,1])!,
    startCenter: .init(x: cx, y: rect.midY), startRadius: 0, endCenter: .init(x: cx, y: rect.midY), endRadius: W*0.75, options: [])
ctx.setBlendMode(.normal)
ctx.restoreGState()
ctx.addPath(shape); ctx.setLineWidth(S*0.003); ctx.setStrokeColor(gray(1,0.14)); ctx.strokePath()

let out = CommandLine.arguments[1]
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/ink.png"))
print("rendered ink")
