import AppKit
import Foundation

@main
enum GenerateUsoIcon {
    private static let pixelSize = 1_024

    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let theme = Theme(rawValue: CommandLine.arguments[2]) else {
            fputs("Usage: GenerateUsoIcon OUTPUT.png light|dark\n", stderr)
            exit(2)
        }

        let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RenderError.couldNotCreateBitmap
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        drawIcon(
            in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            theme: theme
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.couldNotEncodePNG
        }
        try png.write(to: outputURL, options: .atomic)
    }

    private static func drawIcon(in bounds: CGRect, theme: Theme) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.clear(bounds)
        context.setShouldAntialias(true)

        let tileRect = bounds.insetBy(dx: 72, dy: 72)
        let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: 210, yRadius: 210)
        let tileShadow = NSShadow()
        tileShadow.shadowColor = NSColor(
            calibratedWhite: 0,
            alpha: theme == .light ? 0.22 : 0.55
        )
        tileShadow.shadowBlurRadius = 28
        tileShadow.shadowOffset = NSSize(width: 0, height: -16)

        NSGraphicsContext.saveGraphicsState()
        tileShadow.set()
        theme.tileFallback.setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let tileGradient = NSGradient(
            starting: theme.tileStart,
            ending: theme.tileEnd
        )
        tileGradient?.draw(in: tilePath, angle: 90)

        theme.tileBorder.setStroke()
        tilePath.lineWidth = 8
        tilePath.stroke()

        let ringBounds = bounds.insetBy(dx: 160, dy: 160)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -12),
            blur: 22,
            color: NSColor(
                calibratedWhite: 0,
                alpha: theme == .light ? 0.22 : 0.48
            ).cgColor
        )
        drawRings(in: ringBounds)
        context.restoreGState()
    }

    private static func drawRings(in bounds: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(bounds.width, bounds.height) / 22
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let rings: [(CGFloat, CGFloat, NSColor)] = [
            (8.5, 0.8, NSColor(calibratedRed: 0.17, green: 0.62, blue: 0.28, alpha: 0.96)),
            (4.5, 0.65, NSColor(calibratedRed: 0.92, green: 0.61, blue: 0.16, alpha: 0.96)),
        ]
        context.setLineWidth(2.5 * scale)
        context.setLineCap(.round)
        for (radius, remaining, color) in rings {
            context.setStrokeColor(color.cgColor)
            context.addArc(center: center, radius: radius * scale,
                           startAngle: .pi / 2, endAngle: .pi / 2 - remaining * .pi * 2,
                           clockwise: true)
            context.strokePath()
        }
    }

    private enum RenderError: Error {
        case couldNotCreateBitmap
        case couldNotEncodePNG
    }

    private enum Theme: String {
        case light
        case dark

        var tileFallback: NSColor {
            switch self {
            case .light:
                return NSColor(calibratedWhite: 0.98, alpha: 1)
            case .dark:
                return NSColor(calibratedWhite: 0.18, alpha: 1)
            }
        }

        var tileStart: NSColor {
            switch self {
            case .light:
                return NSColor(calibratedWhite: 1.00, alpha: 1)
            case .dark:
                return NSColor(calibratedWhite: 0.251, alpha: 1)
            }
        }

        var tileEnd: NSColor {
            switch self {
            case .light:
                return NSColor(calibratedWhite: 0.956, alpha: 1)
            case .dark:
                return NSColor(calibratedRed: 0.102, green: 0.096, blue: 0.101, alpha: 1)
            }
        }

        var tileBorder: NSColor {
            switch self {
            case .light:
                return NSColor(calibratedWhite: 1, alpha: 0.80)
            case .dark:
                return NSColor(calibratedWhite: 1, alpha: 0.25)
            }
        }
    }
}
