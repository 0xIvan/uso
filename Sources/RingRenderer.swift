import AppKit

enum RingRenderer {
    static let logicalSize = CGSize(width: 22, height: 22)

    static func draw(baseLimits: BaseLimits, in bounds: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let scale = min(bounds.width / logicalSize.width, bounds.height / logicalSize.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let outerRadius = 8.5 * scale
        let innerRadius = 4.5 * scale
        let lineWidth = 2.5 * scale

        context.saveGState()
        context.setShouldAntialias(true)
        if baseLimits.hasExhaustedLimit {
            drawExclamation(center: center, scale: scale, context: context)
            context.restoreGState()
            return
        }
        if baseLimits.fiveHour == nil, baseLimits.weekly == nil {
            drawUnavailableRings(
                center: center,
                outerRadius: outerRadius,
                innerRadius: innerRadius,
                lineWidth: lineWidth,
                context: context
            )
        }
        if let weekly = baseLimits.weekly {
            drawArc(
                bucket: weekly,
                center: center,
                radius: outerRadius,
                lineWidth: lineWidth,
                context: context
            )
        }
        if let fiveHour = baseLimits.fiveHour {
            drawArc(
                bucket: fiveHour,
                center: center,
                radius: innerRadius,
                lineWidth: lineWidth,
                context: context
            )
        }
        context.restoreGState()
    }

    private static func drawExclamation(
        center: CGPoint,
        scale: CGFloat,
        context: CGContext
    ) {
        let color = RingPalette.color(forRemaining: 0)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(2.8 * scale)
        context.setStrokeColor(color.cgColor)
        context.move(to: CGPoint(x: center.x, y: center.y + 5.5 * scale))
        context.addLine(to: CGPoint(x: center.x, y: center.y - 0.5 * scale))
        context.strokePath()
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(
            x: center.x - 1.5 * scale,
            y: center.y - 6.0 * scale,
            width: 3.0 * scale,
            height: 3.0 * scale
        ))
        context.restoreGState()
    }

    private static func drawUnavailableRings(
        center: CGPoint,
        outerRadius: CGFloat,
        innerRadius: CGFloat,
        lineWidth: CGFloat,
        context: CGContext
    ) {
        context.saveGState()
        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor(calibratedWhite: 0.55, alpha: 0.48).cgColor)
        context.strokeEllipse(in: CGRect(
            x: center.x - outerRadius,
            y: center.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))
        context.strokeEllipse(in: CGRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))
        context.restoreGState()
    }

    static func statusImage(baseLimits: BaseLimits) -> NSImage {
        let image = NSImage(size: logicalSize, flipped: false) { bounds in
            draw(baseLimits: baseLimits, in: bounds)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func writePreview(baseLimits: BaseLimits, to path: URL) throws -> CGSize {
        let pixelWidth = 44
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
        draw(baseLimits: baseLimits, in: CGRect(origin: .zero, size: logicalSize))
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
        context.setStrokeColor(RingPalette.color(forRemaining: bucket.remainingPercent).cgColor)
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

    func limits(containing bucket: LimitBucket) -> BaseLimits {
        switch self {
        case .fiveHour:
            return BaseLimits(fiveHour: bucket, weekly: nil)
        case .weekly:
            return BaseLimits(fiveHour: nil, weekly: bucket)
        }
    }
}

final class UsageRingView: NSView {
    private let role: BaseLimitRole
    private let bucket: LimitBucket

    init(role: BaseLimitRole, bucket: LimitBucket) {
        self.role = role
        self.bucket = bucket
        super.init(frame: .zero)
    }

    @available(*, unavailable, message: "Use init(role:bucket:) to preserve ring semantics")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 24, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let insetBounds = bounds.insetBy(dx: 1, dy: 1)
        RingRenderer.draw(baseLimits: role.limits(containing: bucket), in: insetBounds)
    }
}
