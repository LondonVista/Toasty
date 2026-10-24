// Draws the Toasty app icon: a white flame on a warm gradient. Usage: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 100 // macOS icon grid margin
let plate = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                         xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 1, green: 0.72, blue: 0.2, alpha: 1),
           ending: NSColor(red: 0.93, green: 0.27, blue: 0.16, alpha: 1))!.draw(in: plate, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = flame.size
    flame.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
