#!/usr/bin/env swift
// generate-app-icon.swift - Renders the "Outline Precision" app icon at every size
// macOS needs, and packs them into AppIcon.icns.
//
// Renders each size directly from the vector geometry rather than downsampling one
// master PNG: a hairline stroke that reads correctly at 512px is invisible at 16px, so
// stroke weight is optically corrected per size (thicker relative weight small, true
// hairline at full size) while the silhouette stays identical throughout.
//
// usage: swift scripts/generate-app-icon.swift [output-dir, default: AppIcon.iconset]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette (matches the chosen concept exactly)

let paper       = CGColor(red: 0xF4/255, green: 0xF0/255, blue: 0xE8/255, alpha: 1)
let paperBorder = CGColor(red: 0xE3/255, green: 0xDD/255, blue: 0xCE/255, alpha: 1)
let ink         = CGColor(red: 0x1B/255, green: 0x1D/255, blue: 0x1F/255, alpha: 1)

// MARK: - Apple's Big Sur icon grid
//
// Hand-built .icns files (this project doesn't use an Xcode asset catalog) are shown
// exactly as authored — the OS does not add its own squircle mask. So the mask, and the
// ~10% breathing-room margin every native macOS icon has around its content, are both
// baked into these PNGs by hand, matching Apple's published Big Sur icon template:
// a 1024×1024 canvas holding an 824×824 rounded square (radius 185), centered.

let canvasToContent: CGFloat = 824.0 / 1024.0
let contentToRadius: CGFloat = 185.0 / 824.0

/// Stroke width in physical pixels for a render at `size`. Plateaus at a legible floor
/// below 64px (where a proportional hairline would vanish under antialiasing) and scales
/// back to the design's true ~2.6%-of-content hairline ratio above it.
func strokeWidth(forSize size: CGFloat) -> CGFloat {
    max(1.75, size * canvasToContent * 0.026)
}

// MARK: - Drawing

func renderIcon(size: Int) -> CGImage {
    let n = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create bitmap context for size \(size)") }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip to a top-left origin, y-down system so the geometry below (carried over
    // directly from the SVG concept) doesn't need per-point manual flipping.
    ctx.translateBy(x: 0, y: n)
    ctx.scaleBy(x: 1, y: -1)

    let content = n * canvasToContent
    let margin = (n - content) / 2
    let radius = content * contentToRadius
    let contentRect = CGRect(x: margin, y: margin, width: content, height: content)

    // Squircle (approximated as a generously rounded rect — see README "App icon").
    let squircle = CGPath(roundedRect: contentRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(squircle)
    ctx.setFillColor(paper)
    ctx.fillPath()

    if size >= 32 {
        ctx.addPath(squircle)
        ctx.setStrokeColor(paperBorder)
        ctx.setLineWidth(max(1.0, n * 0.0018))
        ctx.strokePath()
    }

    let sw = strokeWidth(forSize: n)

    // Ring ("O"): centered in the content square, 60% of its width in diameter —
    // proportions carried over exactly from the concept's 100-unit viewBox (r=30/100).
    let ringCenter = CGPoint(x: contentRect.midX, y: contentRect.midY)
    let ringRadius = content * 0.30
    ctx.addArc(center: ringCenter, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(sw)
    ctx.strokePath()

    // Chevron ("V"): same viewBox-relative points as the concept — (38,37)-(50,59)-(62,37).
    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: contentRect.minX + fx / 100 * content, y: contentRect.minY + fy / 100 * content)
    }
    let chevron = CGMutablePath()
    chevron.move(to: point(38, 37))
    chevron.addLine(to: point(50, 59))
    chevron.addLine(to: point(62, 37))
    ctx.addPath(chevron)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(sw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    guard let image = ctx.makeImage() else { fatalError("could not rasterize size \(size)") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("could not write PNG at \(url.path)")
    }
}

// MARK: - iconutil's required file set

struct IconEntry { let filename: String; let pixels: Int }

let entries: [IconEntry] = [
    .init(filename: "icon_16x16.png", pixels: 16),
    .init(filename: "icon_16x16@2x.png", pixels: 32),
    .init(filename: "icon_32x32.png", pixels: 32),
    .init(filename: "icon_32x32@2x.png", pixels: 64),
    .init(filename: "icon_128x128.png", pixels: 128),
    .init(filename: "icon_128x128@2x.png", pixels: 256),
    .init(filename: "icon_256x256.png", pixels: 256),
    .init(filename: "icon_256x256@2x.png", pixels: 512),
    .init(filename: "icon_512x512.png", pixels: 512),
    .init(filename: "icon_512x512@2x.png", pixels: 1024),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let outURL = URL(fileURLWithPath: outDir)
try? FileManager.default.removeItem(at: outURL)
try! FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

var cache: [Int: CGImage] = [:]
for entry in entries {
    let image = cache[entry.pixels] ?? renderIcon(size: entry.pixels)
    cache[entry.pixels] = image
    writePNG(image, to: outURL.appendingPathComponent(entry.filename))
    print("  \(entry.filename)  (\(entry.pixels)×\(entry.pixels))")
}
print("Wrote \(entries.count) files to \(outDir)")
