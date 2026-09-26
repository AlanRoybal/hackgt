// Renders the flat pastel app icon (light, dark, tinted) at 1024×1024.
// Run: swift ios/scripts/make-icon.swift <output-dir>
// Motif: two people as overlapping circles; the overlap (shared free time) is mint.
import AppKit
import CoreGraphics

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(bg: CGColor?, left: CGColor, right: CGColor, overlap: CGColor, to path: String) {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let bg {
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    let r: CGFloat = 250
    let cy: CGFloat = 512
    let a = CGRect(x: 512 - 150 - r, y: cy - r, width: r * 2, height: r * 2)
    let b = CGRect(x: 512 + 150 - r, y: cy - r, width: r * 2, height: r * 2)
    ctx.setFillColor(left); ctx.fillEllipse(in: a)
    ctx.setFillColor(right); ctx.fillEllipse(in: b)
    ctx.saveGState()
    ctx.addEllipse(in: a); ctx.clip()
    ctx.setFillColor(overlap); ctx.fillEllipse(in: b)
    ctx.restoreGState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
render(bg: color(0xFBF8F4), left: color(0xC9BEFF), right: color(0xFFBFA0), overlap: color(0x6FC7A0), to: "\(out)/icon-light.png")
render(bg: color(0x15161C), left: color(0x6052BD), right: color(0xC0623A), overlap: color(0x9FE0C2), to: "\(out)/icon-dark.png")
// Tinted: grayscale on transparent; the system applies the tint.
render(bg: nil, left: color(0x8A8A8A), right: color(0xB5B5B5), overlap: color(0xFFFFFF), to: "\(out)/icon-tinted.png")
print("wrote icons to \(out)")
