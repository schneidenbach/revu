// Draws the revu app icon and writes a 1024×1024 PNG to the path given as the first argument.
// Run via scripts/make-icon.sh, which turns it into assets/AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Top-left origin, like the layout numbers below.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ path: CGPath, _ top: CGColor, _ bottom: CGColor, from: CGFloat, to: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to), options: [])
    ctx.restoreGState()
}

// MARK: Background (macOS icon grid: 824pt body centred on a 1024 canvas)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundedRect(body, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x1B2030))
ctx.fillPath()
ctx.restoreGState()
fillGradient(bodyPath, rgb(0x343C52), rgb(0x161A24), from: body.minY, to: body.maxY)
// Hairline highlight on the rim.
ctx.addPath(roundedRect(body.insetBy(dx: 2, dy: 2), 183))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
ctx.setLineWidth(4)
ctx.strokePath()

// MARK: Diff sheet

let sheet = CGRect(x: 196, y: 218, width: 632, height: 540)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x000000, 0.45))
ctx.addPath(roundedRect(sheet, 40))
ctx.setFillColor(rgb(0xF6F7F9))
ctx.fillPath()
ctx.restoreGState()

// Title bar strip with three dots, so it reads as a window.
ctx.saveGState()
ctx.addPath(roundedRect(sheet, 40))
ctx.clip()
ctx.setFillColor(rgb(0xE4E7EC))
ctx.fill(CGRect(x: sheet.minX, y: sheet.minY, width: sheet.width, height: 58))
ctx.restoreGState()
for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
    ctx.setFillColor(rgb(UInt32(color)))
    ctx.fillEllipse(in: CGRect(x: sheet.minX + 30 + CGFloat(i) * 34, y: sheet.minY + 19, width: 20, height: 20))
}

// Centre divider between the two sides.
let midX = sheet.midX
ctx.setFillColor(rgb(0xD5D9E0))
ctx.fill(CGRect(x: midX - 2, y: sheet.minY + 58, width: 4, height: sheet.height - 58))

enum Row { case context(CGFloat), removed(CGFloat), added(CGFloat), filler }

let left: [Row] = [.context(0.62), .context(0.84), .removed(0.74), .removed(0.52), .filler, .context(0.70), .context(0.44)]
let right: [Row] = [.context(0.62), .context(0.84), .added(0.80), .added(0.58), .added(0.66), .context(0.70), .context(0.44)]

let rowTop = sheet.minY + 86
let rowStep: CGFloat = 60
let barHeight: CGFloat = 22
let columnPad: CGFloat = 26

func drawColumn(_ rows: [Row], minX: CGFloat, maxX: CGFloat) {
    let width = maxX - minX
    for (i, row) in rows.enumerated() {
        let centreY = rowTop + CGFloat(i) * rowStep + rowStep / 2
        let band = CGRect(x: minX, y: centreY - rowStep / 2 + 4, width: width, height: rowStep - 8)
        let barX = minX + columnPad
        let barWidth = width - columnPad * 2
        switch row {
        case let .context(f):
            ctx.addPath(roundedRect(CGRect(x: barX, y: centreY - barHeight / 2, width: barWidth * f, height: barHeight), barHeight / 2))
            ctx.setFillColor(rgb(0xBFC5CF))
            ctx.fillPath()
        case let .removed(f):
            ctx.setFillColor(rgb(0xFF453A, 0.16))
            ctx.fill(band)
            ctx.addPath(roundedRect(CGRect(x: barX, y: centreY - barHeight / 2, width: barWidth * f, height: barHeight), barHeight / 2))
            ctx.setFillColor(rgb(0xE5484D))
            ctx.fillPath()
        case let .added(f):
            ctx.setFillColor(rgb(0x30D158, 0.18))
            ctx.fill(band)
            ctx.addPath(roundedRect(CGRect(x: barX, y: centreY - barHeight / 2, width: barWidth * f, height: barHeight), barHeight / 2))
            ctx.setFillColor(rgb(0x2DA44E))
            ctx.fillPath()
        case .filler:
            ctx.setFillColor(rgb(0xE9ECF0))
            ctx.fill(band)
        }
    }
}

ctx.saveGState()
ctx.addPath(roundedRect(sheet, 40))
ctx.clip()
drawColumn(left, minX: sheet.minX, maxX: midX - 2)
drawColumn(right, minX: midX + 2, maxX: sheet.maxX)
ctx.restoreGState()

// MARK: Comment bubble

let bubble = CGRect(x: 588, y: 640, width: 262, height: 176)
let bubblePath = CGMutablePath()
bubblePath.addPath(roundedRect(bubble, 48))
// Tail pointing down-left.
// Drawn in the same winding direction as the rounded rect so the overlap fills instead of cancelling.
bubblePath.move(to: CGPoint(x: bubble.minX + 124, y: bubble.maxY - 20))
bubblePath.addLine(to: CGPoint(x: bubble.minX + 58, y: bubble.maxY + 38))
bubblePath.addQuadCurve(to: CGPoint(x: bubble.minX + 40, y: bubble.maxY + 34), control: CGPoint(x: bubble.minX + 44, y: bubble.maxY + 46))
bubblePath.addLine(to: CGPoint(x: bubble.minX + 46, y: bubble.maxY - 40))
bubblePath.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 26, color: rgb(0x000000, 0.45))
ctx.addPath(bubblePath)
ctx.setFillColor(rgb(0x2F6BFF))
ctx.fillPath()
ctx.restoreGState()
fillGradient(bubblePath, rgb(0x5B93FF), rgb(0x2457E6), from: bubble.minY, to: bubble.maxY + 50)

// Two text lines inside the bubble.
ctx.setFillColor(rgb(0xFFFFFF, 0.95))
ctx.addPath(roundedRect(CGRect(x: bubble.minX + 44, y: bubble.minY + 50, width: 174, height: 24), 12))
ctx.fillPath()
ctx.setFillColor(rgb(0xFFFFFF, 0.75))
ctx.addPath(roundedRect(CGRect(x: bubble.minX + 44, y: bubble.minY + 100, width: 112, height: 24), 12))
ctx.fillPath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
