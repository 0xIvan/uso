import AppKit

enum RingRenderer {
    static func statusImage(limits: [BaseLimits], icons: [NSImage?]? = nil) -> NSImage {
        let size = CGSize(width: max(22, CGFloat(limits.count) * 24 - 2), height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            if limits.isEmpty {
                let text = "u" as NSString
                text.draw(at: CGPoint(x: 6, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor])
            }
            for (index, providerLimits) in limits.enumerated() {
                let bounds = CGRect(x: CGFloat(index) * 24, y: 0, width: 22, height: 22)
                drawPair(limits: providerLimits, in: bounds)
                if let icons, icons.indices.contains(index), let icon = icons[index] {
                    icon.draw(in: CGRect(x: bounds.maxX - 10, y: bounds.minY, width: 10, height: 10), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawPair(limits: BaseLimits, in bounds: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = min(bounds.width, bounds.height) / 22
        context.saveGState()
        context.setLineWidth(2.5 * scale)
        for (bucket, radius) in [(limits.weekly, 8.5 * scale), (limits.fiveHour, 4.5 * scale)] {
            let trackColor: NSColor
            if let bucket, bucket.remainingPercent <= 0 {
                trackColor = PacePalette.color(for: bucket)
            } else {
                trackColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25)
            }
            context.setStrokeColor(trackColor.cgColor)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            if let bucket {
                drawArc(bucket: bucket, center: center, radius: radius, lineWidth: 2.5 * scale, context: context)
            }
        }
        context.restoreGState()
    }

    static func writePreview(limits: [BaseLimits], icons: [NSImage?]? = nil, to path: URL) throws -> CGSize {
        let image = statusImage(limits: limits, icons: icons)
        let pixelWidth = Int(image.size.width * 2)
        let pixelHeight = 44
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw PreviewError.couldNotCreateBitmap
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.cgContext.scaleBy(x: 2, y: 2)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.couldNotEncodePNG
        }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: path, options: .atomic)
        return CGSize(width: pixelWidth, height: pixelHeight)
    }

    private static func drawArc(
        bucket: LimitBucket,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        context: CGContext
    ) {
        let remaining = CGFloat(bucket.remainingPercent / 100.0)
        guard remaining > 0 else {
            return
        }
        let start = CGFloat.pi / 2
        let end = start - remaining * CGFloat.pi * 2
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(lineWidth)
        let color = PacePalette.color(for: bucket)
        context.setStrokeColor(color.cgColor)
        context.addArc(
            center: center,
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: true
        )
        context.strokePath()
        context.restoreGState()
    }

    private enum PreviewError: Error {
        case couldNotCreateBitmap
        case couldNotEncodePNG
    }
}

enum BaseLimitRole {
    case fiveHour
    case weekly
}
