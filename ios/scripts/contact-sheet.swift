// Tiles screenshots into one image for quick review.
// swift ios/scripts/contact-sheet.swift <out.jpg> <columns> <img1> <img2> ...
import AppKit

let args = CommandLine.arguments
guard args.count > 3, let cols = Int(args[2]) else { print("usage: out cols images…"); exit(1) }
let images = args.dropFirst(3).compactMap { NSImage(contentsOfFile: $0) }
let cellW: CGFloat = 300, cellH: CGFloat = 652, gap: CGFloat = 8
let rows = Int(ceil(Double(images.count) / Double(cols)))
let size = NSSize(width: CGFloat(cols) * (cellW + gap) + gap, height: CGFloat(rows) * (cellH + gap) + gap)
let canvas = NSImage(size: size)
canvas.lockFocus()
NSColor(white: 0.5, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
for (i, img) in images.enumerated() {
    let r = i / cols, c = i % cols
    let x = gap + CGFloat(c) * (cellW + gap)
    let y = size.height - CGFloat(r + 1) * (cellH + gap)
    img.draw(in: NSRect(x: x, y: y, width: cellW, height: cellH))
}
canvas.unlockFocus()
let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: URL(fileURLWithPath: args[1]))
print("wrote \(args[1])")
