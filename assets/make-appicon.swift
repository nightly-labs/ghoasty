import AppKit

let srcPath = CommandLine.arguments[1]
let outDir  = CommandLine.arguments[2]
guard let src = NSImage(contentsOfFile: srcPath) else { fatalError("cannot load \(srcPath)") }

// Use the source art exactly as-is: just resize to each icon size, no crop, no clip.
func render(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let rect = CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
    src.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote \(sizes.count) sizes")
