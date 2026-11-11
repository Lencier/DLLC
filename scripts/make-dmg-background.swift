// Draws the install window background for DLLC.dmg: a title, a "Drag here" arrow from the app to Applications,
// and a first-launch note. Usage: swift scripts/make-dmg-background.swift   (run from the repo root)
// Writes Resources/DMG/background.tiff (1× and 2× in one file, so Retina screens get the sharp one).
// The layout matches scripts/build-app.sh: a 660 × 500 window (content in the top 400), the app icon centred at (170, 190) and
// Applications at (490, 190), measured from the window's top-left.
import AppKit

let W: CGFloat = 660, H: CGFloat = 480   // 400 of content + room for Finder's tab and status bars
let appX: CGFloat = 170, appsX: CGFloat = 490, iconY: CGFloat = 190
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = root.appendingPathComponent("Resources/DMG", isDirectory: true)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let brand = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.20, alpha: 1)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Flip so y runs top-down like Finder's icon positions.
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    // Background: the logo's near-black red, a little lighter at the top.
    NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.04, blue: 0.04, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.0, blue: 0.0, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
    // Soft glows behind the two icons so they sit on something.
    for x in [appX, appsX] {
        let glow = NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])!
        glow.draw(fromCenter: NSPoint(x: x, y: iconY), radius: 0, toCenter: NSPoint(x: x, y: iconY), radius: 95, options: [])
    }

    func text(_ s: String, _ font: NSFont, _ color: NSColor, centerX: CGFloat, top: CGFloat) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        let size = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(in: NSRect(x: centerX - 300, y: top, width: 600, height: size.height + 2), withAttributes: a)
    }

    text("Install DLLC", .systemFont(ofSize: 24, weight: .bold), .white, centerX: W / 2, top: 30)
    text("Drag the DLLC icon onto the Applications folder", .systemFont(ofSize: 13, weight: .medium),
         NSColor(white: 1, alpha: 0.72), centerX: W / 2, top: 66)

    // The arrow: a gentle dashed arc from the app to Applications, with a solid head.
    let start = NSPoint(x: appX + 78, y: iconY - 6), end = NSPoint(x: appsX - 84, y: iconY - 6)
    let arc = NSBezierPath()
    arc.move(to: start)
    arc.curve(to: end, controlPoint1: NSPoint(x: start.x + 40, y: iconY - 46), controlPoint2: NSPoint(x: end.x - 40, y: iconY - 46))
    arc.lineWidth = 4; arc.lineCapStyle = .round
    arc.setLineDash([10, 9], count: 2, phase: 0)
    brand.setStroke(); arc.stroke()
    // Head along the curve's end direction (from the last control point to the end).
    let d = (x: 40.0 / 56.57, y: 40.0 / 56.57), n = (x: -d.y, y: d.x)
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x + d.x * 14, y: end.y + d.y * 14))
    head.line(to: NSPoint(x: end.x - d.x * 6 + n.x * 10, y: end.y - d.y * 6 + n.y * 10))
    head.line(to: NSPoint(x: end.x - d.x * 6 - n.x * 10, y: end.y - d.y * 6 - n.y * 10))
    head.close()
    brand.setFill(); head.fill()

    // "Drag here" pill under the arc.
    let label = "Drag here"
    let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let lw = (label as NSString).size(withAttributes: [.font: font]).width + 26
    let pill = NSRect(x: W / 2 - lw / 2, y: iconY + 2, width: lw, height: 26)
    brand.setFill(); NSBezierPath(roundedRect: pill, xRadius: 13, yRadius: 13).fill()
    text(label, font, .white, centerX: W / 2, top: pill.minY + 5)

    // Finder draws the icon names in dark text: give each a light plate so it reads on the dark background.
    for (x, name) in [(appX, "DLLC"), (appsX, "Applications")] {
        let w = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 26
        NSColor(white: 1, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - w / 2, y: iconY + 62, width: w, height: 22), xRadius: 11, yRadius: 11).fill()
    }

    // Footer.
    NSColor(white: 1, alpha: 0.10).setFill()
    NSRect(x: 40, y: 306, width: W - 80, height: 1).fill()
    text("First launch: if macOS says it can’t check the developer,", .systemFont(ofSize: 11),
         NSColor(white: 1, alpha: 0.62), centerX: W / 2, top: 318)
    text("open System Settings › Privacy & Security › Open Anyway.", .systemFont(ofSize: 11, weight: .semibold),
         NSColor(white: 1, alpha: 0.75), centerX: W / 2, top: 334)
    text("Apple silicon Mac · macOS 15 or later", .systemFont(ofSize: 10.5, weight: .medium),
         NSColor(white: 1, alpha: 0.40), centerX: W / 2, top: 360)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let one = render(scale: 1), two = render(scale: 2)
let tmp = FileManager.default.temporaryDirectory
let p1 = tmp.appendingPathComponent("dmg-bg.png"), p2 = tmp.appendingPathComponent("dmg-bg@2x.png")
try! one.representation(using: .png, properties: [:])!.write(to: p1)
try! two.representation(using: .png, properties: [:])!.write(to: p2)
try! two.representation(using: .png, properties: [:])!.write(to: tmp.appendingPathComponent("dmg-preview@2x.png"))   // to look at
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
task.arguments = ["-cathidpicheck", p1.path, p2.path, "-out", out.appendingPathComponent("background.tiff").path]
try! task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "✓ Resources/DMG/background.tiff" : "✗ tiffutil failed")
