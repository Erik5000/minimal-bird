// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import AppKit
import CoreGraphics

// Original vector artwork. Rendered at every macOS icon resolution, without fonts
// or external libraries. All coordinates use a 1024-point design canvas.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int, to url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: pixels, height: pixels,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), cornerWidth: 196, cornerHeight: 196, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.14))
    context.addPath(tile)
    context.setFillColor(CGColor(red: 0.13, green: 0.18, blue: 0.20, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.105, green: 0.145, blue: 0.165, alpha: 1),
        CGColor(red: 0.20, green: 0.26, blue: 0.28, alpha: 1)
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 64), end: CGPoint(x: 512, y: 960), options: [])
    context.restoreGState()

    // An original swift in flight: one lifted wing and a long forked tail.
    // Broad, unoutlined shapes keep the silhouette readable in a small Dock icon.
    let bird = CGMutablePath()
    bird.move(to: CGPoint(x: 798, y: 580))
    bird.addLine(to: CGPoint(x: 738, y: 562))
    bird.addCurve(to: CGPoint(x: 648, y: 575), control1: CGPoint(x: 720, y: 600), control2: CGPoint(x: 681, y: 603))
    bird.addLine(to: CGPoint(x: 598, y: 545))
    bird.addCurve(to: CGPoint(x: 414, y: 770), control1: CGPoint(x: 551, y: 648), control2: CGPoint(x: 496, y: 732))
    bird.addCurve(to: CGPoint(x: 492, y: 518), control1: CGPoint(x: 433, y: 667), control2: CGPoint(x: 453, y: 584))
    bird.addCurve(to: CGPoint(x: 270, y: 594), control1: CGPoint(x: 410, y: 532), control2: CGPoint(x: 329, y: 560))
    bird.addCurve(to: CGPoint(x: 436, y: 432), control1: CGPoint(x: 311, y: 510), control2: CGPoint(x: 374, y: 455))
    bird.addLine(to: CGPoint(x: 258, y: 310))
    bird.addLine(to: CGPoint(x: 441, y: 368))
    bird.addLine(to: CGPoint(x: 399, y: 283))
    bird.addCurve(to: CGPoint(x: 617, y: 448), control1: CGPoint(x: 505, y: 326), control2: CGPoint(x: 570, y: 386))
    bird.addCurve(to: CGPoint(x: 741, y: 544), control1: CGPoint(x: 658, y: 494), control2: CGPoint(x: 701, y: 533))
    bird.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 12, color: CGColor(gray: 0, alpha: 0.12))
    context.addPath(bird)
    context.setFillColor(CGColor(red: 0.98, green: 0.975, blue: 0.95, alpha: 1))
    context.fillPath()
    context.restoreGState()

    let image = context.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    try render(points, to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2, to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try render(1024, to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("Rendered macOS icon set")
