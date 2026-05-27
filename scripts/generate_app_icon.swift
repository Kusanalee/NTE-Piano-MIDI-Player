#!/usr/bin/env swift

import AppKit
import Foundation

struct IconSize {
    let filename: String
    let pixels: CGFloat
}

let sizes = [
    IconSize(filename: "icon_16x16.png", pixels: 16),
    IconSize(filename: "icon_16x16@2x.png", pixels: 32),
    IconSize(filename: "icon_32x32.png", pixels: 32),
    IconSize(filename: "icon_32x32@2x.png", pixels: 64),
    IconSize(filename: "icon_128x128.png", pixels: 128),
    IconSize(filename: "icon_128x128@2x.png", pixels: 256),
    IconSize(filename: "icon_256x256.png", pixels: 256),
    IconSize(filename: "icon_256x256@2x.png", pixels: 512),
    IconSize(filename: "icon_512x512.png", pixels: 512),
    IconSize(filename: "icon_512x512@2x.png", pixels: 1024)
]

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift <output.iconset>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

for size in sizes {
    let image = drawIcon(pixelSize: size.pixels)
    let destination = outputURL.appendingPathComponent(size.filename)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("failed to render \(size.filename)\n", stderr)
        exit(1)
    }
    try png.write(to: destination)
}

func drawIcon(pixelSize: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
    image.lockFocus()
    defer { image.unlockFocus() }

    let scale = pixelSize / 1024.0
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
    }
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x * scale, y: y * scale)
    }
    func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: image.size).fill()

    let background = NSBezierPath(roundedRect: rect(64, 64, 896, 896), xRadius: 206 * scale, yRadius: 206 * scale)
    NSGradient(colors: [
        color(20, 33, 61),
        color(39, 50, 79),
        color(11, 16, 32)
    ])?.draw(in: background, angle: -48)

    let arc = NSBezierPath()
    arc.move(to: point(214, 652))
    arc.curve(to: point(810, 652), controlPoint1: point(306, 474), controlPoint2: point(718, 474))
    color(246, 200, 95).setStroke()
    arc.lineWidth = 52 * scale
    arc.lineCapStyle = .round
    arc.stroke()

    color(248, 250, 252).setFill()
    NSBezierPath(roundedRect: rect(214, 458, 596, 222), xRadius: 34 * scale, yRadius: 34 * scale).fill()
    color(203, 213, 225).setStroke()
    let separator = NSBezierPath()
    separator.move(to: point(214, 594))
    separator.line(to: point(810, 594))
    separator.lineWidth = 12 * scale
    separator.stroke()

    color(17, 24, 39).setFill()
    for x in [286, 396, 566, 676] as [CGFloat] {
        NSBezierPath(roundedRect: rect(x, 458, 50, 140), xRadius: 12 * scale, yRadius: 12 * scale).fill()
    }

    color(148, 163, 184).setStroke()
    let midiLine = NSBezierPath()
    midiLine.move(to: point(312, 344))
    midiLine.line(to: point(512, 300))
    midiLine.line(to: point(712, 344))
    midiLine.lineWidth = 18 * scale
    midiLine.lineCapStyle = .round
    midiLine.lineJoinStyle = .round
    midiLine.stroke()

    for (x, y, fill) in [
        (CGFloat(312), CGFloat(344), color(89, 195, 195)),
        (CGFloat(512), CGFloat(300), color(246, 200, 95)),
        (CGFloat(712), CGFloat(344), color(232, 72, 85))
    ] {
        fill.setFill()
        NSBezierPath(ovalIn: rect(x - 24, y - 24, 48, 48)).fill()
    }

    drawText("NTE", in: rect(160, 714, 704, 126), size: 124 * scale, weight: .heavy, color: color(248, 250, 252))
    drawText("# / b", in: rect(240, 814, 544, 72), size: 56 * scale, weight: .bold, color: color(246, 200, 95))

    return image
}

func drawText(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
}
