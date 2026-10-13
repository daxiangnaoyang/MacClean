import AppKit

enum IconMaker {
    @MainActor static func write(to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw cleanError("无法创建图标画布") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 194, yRadius: 194)
        NSGradient(colors: [NSColor(red: 0.13, green: 0.19, blue: 0.24, alpha: 1), NSColor(red: 0.04, green: 0.075, blue: 0.11, alpha: 1)])!.draw(in: background, angle: -55)
        let mint = NSColor(red: 0.24, green: 0.85, blue: 0.73, alpha: 1)
        let ring = NSBezierPath(ovalIn: NSRect(x: 238, y: 260, width: 548, height: 548))
        ring.lineWidth = 52
        mint.setStroke(); ring.stroke()
        let storage = NSBezierPath(roundedRect: NSRect(x: 276, y: 236, width: 472, height: 174), xRadius: 48, yRadius: 48)
        NSColor(red: 0.11, green: 0.16, blue: 0.2, alpha: 1).setFill(); storage.fill()
        storage.lineWidth = 22; mint.setStroke(); storage.stroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: 329, y: 323)); line.line(to: NSPoint(x: 544, y: 323)); line.lineWidth = 22; line.lineCapStyle = .round; mint.setStroke(); line.stroke()
        mint.setFill(); NSBezierPath(ovalIn: NSRect(x: 643, y: 309, width: 28, height: 28)).fill()
        let check = NSBezierPath(); check.move(to: NSPoint(x: 395, y: 565)); check.line(to: NSPoint(x: 476, y: 486)); check.line(to: NSPoint(x: 627, y: 650)); check.lineWidth = 45; check.lineCapStyle = .round; check.lineJoinStyle = .round; mint.setStroke(); check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw cleanError("图标生成失败") }
        func integer(_ n: Int) -> Data { var v = UInt32(n).bigEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        var chunk = Data("ic10".utf8); chunk.append(integer(png.count + 8)); chunk.append(png)
        var icns = Data("icns".utf8); icns.append(integer(chunk.count + 8)); icns.append(chunk)
        try icns.write(to: url, options: .atomic)
    }
}
