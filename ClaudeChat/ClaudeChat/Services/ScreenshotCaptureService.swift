import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenshotCaptureError: LocalizedError {
    case permissionDenied
    case captureFailed(String)
    case noDisplays
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Keine Berechtigung für Bildschirmaufnahme."
        case .captureFailed(let detail):
            return "Screenshot fehlgeschlagen: \(detail)"
        case .noDisplays:
            return "Kein Display für die Aufnahme gefunden."
        case .cropFailed:
            return "Bereich konnte nicht zugeschnitten werden."
        }
    }
}

@MainActor
final class ScreenshotCaptureService {
    private let store = ScreenshotStore.shared
    private let regionController = RegionSelectionController()

    func captureFullscreen() async throws -> String {
        guard ScreenCapturePermissionManager.hasPermission() else {
            if !ScreenCapturePermissionManager.ensurePermission() {
                throw ScreenshotCaptureError.permissionDenied
            }
            throw ScreenshotCaptureError.permissionDenied
        }

        let image = try await captureAllDisplaysComposite()
        return try store.savePNG(image)
    }

    func captureRegion() async throws -> String {
        guard ScreenCapturePermissionManager.hasPermission() else {
            if !ScreenCapturePermissionManager.ensurePermission() {
                throw ScreenshotCaptureError.permissionDenied
            }
            throw ScreenshotCaptureError.permissionDenied
        }

        guard let region = await regionController.selectRegion() else {
            throw ScreenshotCaptureError.captureFailed("Auswahl abgebrochen")
        }

        let fullImage = try await captureAllDisplaysComposite()
        let unionRect = screenUnionRect()

        guard let cropped = cropImage(fullImage, region: region, unionRect: unionRect) else {
            throw ScreenshotCaptureError.cropFailed
        }

        return try store.savePNG(cropped)
    }

    private func screenUnionRect() -> CGRect {
        NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    }

    private func captureAllDisplaysComposite() async throws -> CGImage {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw ScreenshotCaptureError.noDisplays }

        let unionRect = screenUnionRect()

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = CGFloat.leastNormalMagnitude
        var maxY = CGFloat.leastNormalMagnitude

        var captures: [(image: CGImage, frame: CGRect)] = []

        for screen in screens {
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            guard let scDisplay = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }

            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = scDisplay.width
            configuration.height = scDisplay.height
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            captures.append((image: image, frame: screen.frame))

            minX = min(minX, screen.frame.minX)
            minY = min(minY, screen.frame.minY)
            maxX = max(maxX, screen.frame.maxX)
            maxY = max(maxY, screen.frame.maxY)
        }

        guard !captures.isEmpty else { throw ScreenshotCaptureError.noDisplays }

        let compositeWidth = Int(maxX - minX)
        let compositeHeight = Int(maxY - minY)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: compositeWidth,
            height: compositeHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenshotCaptureError.captureFailed("Bitmap-Kontext konnte nicht erstellt werden")
        }

        for capture in captures {
            let offsetX = capture.frame.origin.x - minX
            let offsetY = capture.frame.origin.y - minY
            let drawRect = CGRect(
                x: offsetX,
                y: offsetY,
                width: capture.frame.width,
                height: capture.frame.height
            )
            context.draw(capture.image, in: drawRect)
        }

        guard let composite = context.makeImage() else {
            throw ScreenshotCaptureError.captureFailed("Composite-Bild konnte nicht erstellt werden")
        }

        return composite
    }

    private func cropImage(_ image: CGImage, region: CGRect, unionRect: CGRect) -> CGImage? {
        let scaleX = CGFloat(image.width) / unionRect.width
        let scaleY = CGFloat(image.height) / unionRect.height

        let cropRect = CGRect(
            x: (region.origin.x - unionRect.origin.x) * scaleX,
            y: (region.origin.y - unionRect.origin.y) * scaleY,
            width: region.width * scaleX,
            height: region.height * scaleY
        ).integral

        guard cropRect.width > 0, cropRect.height > 0 else { return nil }
        return image.cropping(to: cropRect)
    }
}
