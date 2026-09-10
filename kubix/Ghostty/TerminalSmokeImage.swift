#if DEBUG
import AppKit
import IOSurface

@MainActor
enum TerminalSmokeImage {
    enum CaptureError: Error { case noPresentedFrame, invalidFrame, lockFailed }

    /// The pinned Metal renderer presents completed GPU frames as CALayer.contents IOSurfaces
    /// (renderer/metal/IOSurfaceLayer.zig). Read only our own view's presented pixels, not the screen.
    /// Unlike screen capture this requires no TCC permission and cannot capture another app's content.
    static func capture(_ view: GhosttySurfaceView) throws -> CGImage {
        guard let surface = view.layer?.contents as? IOSurface else { throw CaptureError.noPresentedFrame }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let stride = IOSurfaceGetBytesPerRow(surface)
        let backing = view.convertToBacking(view.bounds).size
        guard width == Int(backing.width), height == Int(backing.height),
              IOSurfaceGetBytesPerElement(surface) == 4, IOSurfaceGetPixelFormat(surface) == 0x42475241 else {
            throw CaptureError.invalidFrame
        }
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { throw CaptureError.lockFailed }
        let bytes: Data
        do {
            defer { IOSurfaceUnlock(surface, .readOnly, nil) }
            let base = IOSurfaceGetBaseAddress(surface)
            bytes = Data(bytes: base, count: stride * height)
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                space: space, bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { throw CaptureError.invalidFrame }
        return image
    }
}
#endif
