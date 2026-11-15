import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures, a PDF and buddy pictures for `--demo`, drawn in code at launch into a temporary
/// folder. Abstract shapes only: no real people, places or brands.
struct DemoArt {
    let directory: URL
    let porchCat: URL
    let weddingWide: URL
    /// Stored as landscape pixels with EXIF orientation 6: must display as portrait.
    let weddingTall: URL
    let cabinView: URL
    let tiny: URL
    let sticker: URL
    let animated: URL
    let previewImage: URL
    let previewIcon: URL
    let menuIcon: URL
    let itinerary: URL
    /// A short H.264 clip (nil if it could not be written).
    let clip: URL?
    let slides: [URL]
    /// Buddy pictures keyed by handle ("me" for the user).
    let avatars: [String: Data]

    static func make() -> DemoArt {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LionMessagesDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

        let porchCat = url("IMG_0412.jpg")
        write(draw(1200, 900, porchCatScene), to: porchCat, type: .jpeg)
        let weddingWide = url("IMG_2207.jpg")
        write(draw(1600, 1067, sunsetScene), to: weddingWide, type: .jpeg)
        let weddingTall = url("IMG_2213.jpg")
        write(rotatedForOrientation6(draw(900, 1350, lanternScene)), to: weddingTall, type: .jpeg, orientation: 6)
        let cabinView = url("IMG_3001.heic")
        if !write(draw(1400, 933, lakeScene), to: cabinView, type: .heic) {
            write(draw(1400, 933, lakeScene), to: cabinView, type: .jpeg)
        }
        let tiny = url("pixel-cactus.png")
        write(draw(48, 36, pixelCactus), to: tiny, type: .png)
        let sticker = url("sticker-heart.png")
        write(draw(360, 360, opaque: false, heartSticker), to: sticker, type: .png)
        let animated = url("wave.gif")
        writeGIF([draw(320, 240) { waveFrame($0, $1, 0) }, draw(320, 240) { waveFrame($0, $1, 1) }], to: animated)
        let previewImage = url("preview-lakeside.jpg")
        write(draw(1200, 630, trailCardScene), to: previewImage, type: .jpeg)
        let previewIcon = url("trails-icon.png")
        write(draw(64, 64, opaque: false, trailIcon), to: previewIcon, type: .png)
        let menuIcon = url("menu-icon.png")
        write(draw(64, 64, opaque: false, menuIconArt), to: menuIcon, type: .png)
        let itinerary = url("Cabin Weekend Itinerary.pdf")
        writePDF(to: itinerary)
        let clipURL = url("IMG_3010.mov")
        let clip = writeClip(to: clipURL) ? clipURL : nil
        var slides: [URL] = []
        for i in 0..<12 {
            let u = url(String(format: "whiteboard-%02d.png", i + 1))
            write(draw(160, 120) { slideArt($0, $1, i) }, to: u, type: .png)
            slides.append(u)
        }

        var avatars: [String: Data] = [:]
        let people: [(String, String, UInt32, UInt32)] = [
            ("+14155550123", "ML", 0xf2a65a, 0xc2562f),
            ("+14155550160", "NF", 0x7cc6a5, 0x2f7d6b),
            ("+14155550167", "D", 0x8fa6c8, 0x3e5680),
            ("jonah.p@example.com", "JP", 0xd7a0d9, 0x7c4a8c),
        ]
        for (handle, initials, top, bottom) in people {
            if let data = png(draw(256, 256) { monogram($0, $1, initials, top, bottom) }) { avatars[handle] = data }
        }
        if let data = png(draw(256, 256, meAvatar)) { avatars["me"] = data }

        return DemoArt(directory: dir, porchCat: porchCat, weddingWide: weddingWide, weddingTall: weddingTall,
                       cabinView: cabinView, tiny: tiny, sticker: sticker, animated: animated,
                       previewImage: previewImage, previewIcon: previewIcon, menuIcon: menuIcon,
                       itinerary: itinerary, clip: clip, slides: slides, avatars: avatars)
    }

    // MARK: Encoding

    private static func draw(_ w: Int, _ h: Int, opaque: Bool = true,
                             _ body: (CGContext, CGSize) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue
                                               : CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Top-left origin, like a picture.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        body(ctx, CGSize(width: w, height: h))
        return ctx.makeImage()!
    }

    @discardableResult
    private static func write(_ image: CGImage, to url: URL, type: UTType, orientation: Int? = nil) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private static func writeGIF(_ frames: [CGImage], to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in frames {
            CGImageDestinationAddImage(dest, f, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Pixels that display as `image` once EXIF orientation 6 (rotate 90° clockwise) is applied.
    private static func rotatedForOrientation6(_ image: CGImage) -> CGImage {
        let w = image.height, h = image.width
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Rotate 90° counter-clockwise.
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    private static func writePDF(to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "Cabin Weekend", attributes: [.font: LionFont.bold(28)]).draw(at: NSPoint(x: 72, y: 690))
        let lines = ["Friday — drive up, groceries on the way", "Saturday — lakeside loop, 6.2 mi",
                     "Sunday — pancakes, pack up by 11"]
        for (i, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: LionFont.regular(14)])
                .draw(at: NSPoint(x: 72, y: 640 - CGFloat(i) * 26))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Twelve frames of a sunrise over the lake, encoded synchronously (off the main queue).
    private static func writeClip(to url: URL) -> Bool {
        try? FileManager.default.removeItem(at: url)
        let w = 640, h = 360
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<12 {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1, y: -1)
                let s = CGSize(width: w, height: h)
                lakeScene(ctx, s)
                ctx.setFillColor(color(0xfff1b8))
                ctx.fillEllipse(in: CGRect(x: 420, y: 150 - CGFloat(i) * 6, width: 60, height: 60))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 12))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }

    // MARK: Drawing helpers

    private static func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    private static func gradient(_ ctx: CGContext, _ top: UInt32, _ bottom: UInt32, from y0: CGFloat, to y1: CGFloat) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func hills(_ ctx: CGContext, _ s: CGSize, base: CGFloat, amp: CGFloat, phase: CGFloat, _ c: UInt32) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: s.height))
        for x in stride(from: 0, through: s.width, by: 8) {
            let y = base + amp * sin(x / s.width * 2.6 * .pi + phase) + amp * 0.4 * sin(x / s.width * 7 * .pi + phase * 2)
            ctx.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.addLine(to: CGPoint(x: s.width, y: s.height))
        ctx.closePath()
        ctx.setFillColor(color(c))
        ctx.fillPath()
    }

    // MARK: Scenes

    private static func porchCatScene(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, 0xb98a5e, 0x7a5233, from: 0, to: s.height)
        for i in 0..<9 {
            ctx.setFillColor(color(0x5c3b22, 0.55))
            ctx.fill(CGRect(x: 0, y: CGFloat(i) * 100 + 96, width: s.width, height: 5))
        }
        let cx = s.width * 0.5, cy = s.height * 0.58
        ctx.setFillColor(color(0x000000, 0.18))
        ctx.fillEllipse(in: CGRect(x: cx - 250, y: cy + 150, width: 500, height: 70))
        ctx.setFillColor(color(0xe9944a))
        ctx.fillEllipse(in: CGRect(x: cx - 230, y: cy - 40, width: 460, height: 230))      // body
        ctx.fillEllipse(in: CGRect(x: cx - 150, y: cy - 250, width: 300, height: 260))     // head
        for dx in [-1.0, 1.0] {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cx + dx * 140, y: cy - 170))
            ctx.addLine(to: CGPoint(x: cx + dx * 120, y: cy - 310))
            ctx.addLine(to: CGPoint(x: cx + dx * 40, y: cy - 235))
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.setFillColor(color(0xfbe3c8))
        ctx.fillEllipse(in: CGRect(x: cx - 80, y: cy - 120, width: 160, height: 110))      // muzzle
        ctx.setFillColor(color(0x2b4d2f))
        for dx in [-60.0, 60.0] { ctx.fillEllipse(in: CGRect(x: cx + dx - 22, y: cy - 175, width: 44, height: 52)) }
        ctx.setFillColor(color(0x111111))
        for dx in [-60.0, 60.0] { ctx.fillEllipse(in: CGRect(x: cx + dx - 8, y: cy - 168, width: 16, height: 38)) }
        ctx.setFillColor(color(0xd96a7a))
        ctx.fillEllipse(in: CGRect(x: cx - 14, y: cy - 98, width: 28, height: 18))
        ctx.setStrokeColor(color(0xc7743a))
        ctx.setLineWidth(10)
        for i in 0..<4 {
            ctx.strokeLineSegments(between: [CGPoint(x: cx - 190 + CGFloat(i) * 30, y: cy + 10),
                                             CGPoint(x: cx - 170 + CGFloat(i) * 30, y: cy + 80)])
        }
    }

    private static func sunsetScene(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, 0x3b4f8f, 0xf6a76b, from: 0, to: s.height * 0.7)
        ctx.setFillColor(color(0xffe2a8))
        ctx.fillEllipse(in: CGRect(x: s.width * 0.62, y: s.height * 0.42, width: 170, height: 170))
        hills(ctx, s, base: s.height * 0.68, amp: 40, phase: 0.4, 0x5b4a6b)
        hills(ctx, s, base: s.height * 0.8, amp: 28, phase: 2.1, 0x2f2a3d)
        for i in 0..<22 {
            let x = CGFloat(i) / 21 * s.width
            let y = s.height * 0.18 + 60 * sin(CGFloat(i) / 21 * .pi)
            ctx.setFillColor(color(0xfff2c2, 0.9))
            ctx.fillEllipse(in: CGRect(x: x - 9, y: y - 9, width: 18, height: 18))
        }
    }

    private static func lanternScene(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, 0x1d2347, 0x6b4a7e, from: 0, to: s.height)
        ctx.setFillColor(color(0xfff6d8))
        ctx.fillEllipse(in: CGRect(x: s.width * 0.5 - 70, y: 110, width: 140, height: 140))   // moon at the top
        for i in 0..<7 {
            let x = s.width * (0.15 + 0.12 * CGFloat(i))
            let y = s.height * (0.35 + 0.07 * CGFloat(i % 3))
            ctx.setFillColor(color(0xffb347, 0.95))
            ctx.fill(CGRect(x: x - 26, y: y - 40, width: 52, height: 80))
            ctx.setFillColor(color(0xffe08a, 0.5))
            ctx.fillEllipse(in: CGRect(x: x - 60, y: y - 60, width: 120, height: 120))
        }
        ctx.setFillColor(color(0x15132a))
        ctx.fill(CGRect(x: s.width * 0.47, y: s.height * 0.62, width: s.width * 0.06, height: s.height * 0.38)) // tall tree trunk
        ctx.fillEllipse(in: CGRect(x: s.width * 0.2, y: s.height * 0.5, width: s.width * 0.6, height: s.height * 0.22))
    }

    private static func lakeScene(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, 0x8ec5ea, 0xe9f3f7, from: 0, to: s.height * 0.5)
        hills(ctx, s, base: s.height * 0.42, amp: 70, phase: 1.2, 0x7d8fa6)
        hills(ctx, s, base: s.height * 0.52, amp: 30, phase: 3.0, 0x3f6b4f)
        ctx.setFillColor(color(0x4f8fb8))
        ctx.fill(CGRect(x: 0, y: s.height * 0.6, width: s.width, height: s.height * 0.4))
        for i in 0..<14 {
            ctx.setFillColor(color(0xffffff, 0.35))
            ctx.fill(CGRect(x: CGFloat(i * 97 % 1300), y: s.height * 0.64 + CGFloat(i * 23 % 300), width: 90, height: 4))
        }
        ctx.setFillColor(color(0x6b4a2e))
        ctx.fill(CGRect(x: 0, y: s.height * 0.86, width: s.width, height: s.height * 0.14))
    }

    private static func pixelCactus(_ ctx: CGContext, _ s: CGSize) {
        ctx.setFillColor(color(0xf7e7c6))
        ctx.fill(CGRect(origin: .zero, size: s))
        ctx.setFillColor(color(0x3e8e4f))
        ctx.fill(CGRect(x: 20, y: 6, width: 8, height: 24))
        ctx.fill(CGRect(x: 12, y: 12, width: 4, height: 10))
        ctx.fill(CGRect(x: 12, y: 20, width: 8, height: 4))
        ctx.fill(CGRect(x: 32, y: 10, width: 4, height: 8))
        ctx.fill(CGRect(x: 28, y: 16, width: 8, height: 4))
        ctx.setFillColor(color(0xc0643b))
        ctx.fill(CGRect(x: 16, y: 28, width: 16, height: 6))
    }

    private static func heartSticker(_ ctx: CGContext, _ s: CGSize) {
        func heart(_ inset: CGFloat) -> CGPath {
            let p = CGMutablePath()
            let w = s.width - 2 * inset, h = s.height - 2 * inset
            let x = inset, y = inset
            p.move(to: CGPoint(x: x + w / 2, y: y + h * 0.95))
            p.addCurve(to: CGPoint(x: x, y: y + h * 0.32), control1: CGPoint(x: x + w * 0.2, y: y + h * 0.75),
                       control2: CGPoint(x: x, y: y + h * 0.55))
            p.addArc(center: CGPoint(x: x + w * 0.25, y: y + h * 0.3), radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addArc(center: CGPoint(x: x + w * 0.75, y: y + h * 0.3), radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addCurve(to: CGPoint(x: x + w / 2, y: y + h * 0.95), control1: CGPoint(x: x + w, y: y + h * 0.55),
                       control2: CGPoint(x: x + w * 0.8, y: y + h * 0.75))
            return p
        }
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 10, color: color(0x000000, 0.25))
        ctx.addPath(heart(14))
        ctx.setFillColor(color(0xffffff))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(heart(34))
        ctx.setFillColor(color(0xe8445a))
        ctx.fillPath()
        ctx.setFillColor(color(0xffffff, 0.45))
        ctx.fillEllipse(in: CGRect(x: 92, y: 96, width: 56, height: 34))
    }

    private static func waveFrame(_ ctx: CGContext, _ s: CGSize, _ frame: Int) {
        gradient(ctx, 0xfde68a, 0xf59e0b, from: 0, to: s.height)
        ctx.setFillColor(color(0x8a4b0f))
        ctx.fillEllipse(in: CGRect(x: 110, y: 50, width: 100, height: 100))
        ctx.setStrokeColor(color(0x8a4b0f))
        ctx.setLineWidth(16)
        ctx.setLineCap(.round)
        let angle: CGFloat = frame == 0 ? -0.6 : -1.2
        ctx.strokeLineSegments(between: [CGPoint(x: 205, y: 120), CGPoint(x: 205 + 70 * cos(angle), y: 120 + 70 * sin(angle))])
        ctx.setFillColor(color(0xffffff))
        ctx.fillEllipse(in: CGRect(x: 135, y: 85, width: 14, height: 14))
        ctx.fillEllipse(in: CGRect(x: 171, y: 85, width: 14, height: 14))
    }

    private static func trailCardScene(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, 0xa7d3f0, 0xf1e6c8, from: 0, to: s.height * 0.6)
        hills(ctx, s, base: s.height * 0.5, amp: 60, phase: 0.2, 0x6f8f72)
        hills(ctx, s, base: s.height * 0.66, amp: 26, phase: 2.4, 0x3b6046)
        ctx.setStrokeColor(color(0xe8d6a8))
        ctx.setLineWidth(18)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: s.width * 0.35, y: s.height))
        ctx.addCurve(to: CGPoint(x: s.width * 0.6, y: s.height * 0.62), control1: CGPoint(x: s.width * 0.6, y: s.height * 0.9),
                     control2: CGPoint(x: s.width * 0.4, y: s.height * 0.7))
        ctx.strokePath()
    }

    private static func trailIcon(_ ctx: CGContext, _ s: CGSize) {
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: s), cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.setFillColor(color(0x2f7d4f))
        ctx.fillPath()
        ctx.setFillColor(color(0xffffff))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 10, y: 50))
        ctx.addLine(to: CGPoint(x: 28, y: 18))
        ctx.addLine(to: CGPoint(x: 38, y: 34))
        ctx.addLine(to: CGPoint(x: 44, y: 26))
        ctx.addLine(to: CGPoint(x: 56, y: 50))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func menuIconArt(_ ctx: CGContext, _ s: CGSize) {
        ctx.setFillColor(color(0xb5402f))
        ctx.fillEllipse(in: CGRect(origin: .zero, size: s))
        ctx.setFillColor(color(0xffffff))
        ctx.fill(CGRect(x: 20, y: 16, width: 6, height: 34))
        ctx.fill(CGRect(x: 38, y: 16, width: 6, height: 34))
        ctx.fill(CGRect(x: 18, y: 16, width: 10, height: 12))
    }

    private static func slideArt(_ ctx: CGContext, _ s: CGSize, _ i: Int) {
        ctx.setFillColor(color(0xf8f8f4))
        ctx.fill(CGRect(origin: .zero, size: s))
        let palette: [UInt32] = [0x2b6cb0, 0xc53030, 0x2f855a, 0x6b46c1]
        ctx.setStrokeColor(color(palette[i % 4]))
        ctx.setLineWidth(3)
        for row in 0..<3 {
            let y = 24 + CGFloat(row) * 28
            ctx.strokeLineSegments(between: [CGPoint(x: 18, y: y), CGPoint(x: 40 + CGFloat((i * 37 + row * 23) % 90), y: y)])
        }
        ctx.strokeEllipse(in: CGRect(x: 110, y: 70, width: 36, height: 36))
    }

    private static func monogram(_ ctx: CGContext, _ s: CGSize, _ initials: String, _ top: UInt32, _ bottom: UInt32) {
        gradient(ctx, top, bottom, from: 0, to: s.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let str = NSAttributedString(string: initials, attributes: [
            .font: LionFont.bold(104), .foregroundColor: NSColor(white: 1, alpha: 0.92),
        ])
        let size = str.size()
        str.draw(at: NSPoint(x: (s.width - size.width) / 2, y: (s.height - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func meAvatar(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, 0x5aa0e6, 0xbfe3f7, from: 0, to: s.height * 0.7)
        ctx.setFillColor(color(0xfff3b0))
        ctx.fillEllipse(in: CGRect(x: 160, y: 40, width: 56, height: 56))
        hills(ctx, s, base: s.height * 0.62, amp: 34, phase: 0.8, 0x4c6a8a)
        hills(ctx, s, base: s.height * 0.78, amp: 18, phase: 2.2, 0x2e4a3a)
    }
}
