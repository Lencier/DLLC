// Builds DLLC's icon and sidebar logo from the brand artwork in Resources/Brand.
// Usage: swift scripts/make-icon.swift            (run from the repo root)
// Writes: Resources/AppIcon.icns, Resources/Brand/Logo.png (white LC, for dark mode),
//         Resources/Brand/LogoLight.png (dark LC, for light mode).
//
// Source: Resources/Brand/logo-source.png — the DL/LC monogram on a transparent background (DL red, LC white),
// 1000 × 1000. The icon puts it on the logo's own near-black red (#1A0000) in a macOS squircle.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brand = root.appendingPathComponent("Resources/Brand")
guard let source = NSImage(contentsOf: brand.appendingPathComponent("logo-source.png")),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("missing Resources/Brand/logo-source.png")
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let background = CGColor(srgbRed: 0x1A / 255, green: 0, blue: 0, alpha: 1)

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func writePNG(_ image: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// The monogram's own bounds (opaque pixels), so the sidebar logo has no empty margin.
func opaqueBounds(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    let ctx = context(w, h)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h { for x in 0..<w where data[(y * ctx.bytesPerRow) + x * 4 + 3] > 8 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    // CGContext rows run bottom-up; convert to the image's top-down crop rect.
    return CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1).insetBy(dx: -6, dy: -6)
}

// MARK: Sidebar logos

let crop = cg.cropping(to: opaqueBounds(cg).intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)))!
writePNG(crop, brand.appendingPathComponent("Logo.png"))

// Light mode: the white "LC" becomes the logo's dark red-black so it shows on a light sidebar.
do {
    let w = crop.width, h = crop.height
    let ctx = context(w, h)
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h { for x in 0..<w {
        let i = y * ctx.bytesPerRow + x * 4
        let a = Int(p[i + 3]); guard a > 0 else { continue }
        let g = Int(p[i + 1]) * 255 / a            // un-premultiplied green: high only in the white LC
        if g > 110 {
            let t = Double(g - 110) / 145          // 0 at red edges … 1 in pure white
            let r0 = Double(p[i]) , g0 = Double(p[i + 1]), b0 = Double(p[i + 2])
            let dark = (r: 0x2A * Double(a) / 255, g: 0.0, b: 0.0)
            p[i] = UInt8(r0 + (dark.r - r0) * t); p[i + 1] = UInt8(g0 + (dark.g - g0) * t); p[i + 2] = UInt8(b0 + (dark.b - b0) * t)
        }
    } }
    writePNG(ctx.makeImage()!, brand.appendingPathComponent("LogoLight.png"))
}

// MARK: App icon

let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func icon(_ size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = context(size, size)
    // macOS icon grid: an 824/1024 squircle with a soft shadow.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(path); ctx.setFillColor(background); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path); ctx.clip()
    // The cropped monogram, aspect-fit into the middle ~68% of the tile so it never crowds the edges.
    let box = tile.insetBy(dx: tile.width * 0.16, dy: tile.width * 0.16)
    let k = min(box.width / CGFloat(crop.width), box.height / CGFloat(crop.height))
    let aw = CGFloat(crop.width) * k, ah = CGFloat(crop.height) * k
    let art = CGRect(x: box.midX - aw / 2, y: box.midY - ah / 2, width: aw, height: ah)
    ctx.interpolationQuality = .high
    ctx.draw(crop, in: art)
    return ctx.makeImage()!
}

for base in [16, 32, 128, 256, 512] {
    writePNG(icon(base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(icon(base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "✓ AppIcon.icns, Logo.png, LogoLight.png" : "✗ iconutil failed")
