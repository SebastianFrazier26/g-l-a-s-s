import CoreGraphics
import CoreImage
import CoreVideo
import GlassContrast

/// 8-bit sRGB RGBA pixels, top-left origin. The common currency between captures, tests and
/// the text-region analysis, kept deliberately simple so it can be built from synthetic data.
public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    public var data: [UInt8]

    public struct Pixel: Equatable, Sendable {
        public let r: UInt8, g: UInt8, b: UInt8, a: UInt8
        public var rgb: RGB { RGB(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255) }
    }

    public init(width: Int, height: Int, data: [UInt8]) {
        precondition(data.count == width * height * 4)
        self.width = width
        self.height = height
        self.data = data
    }

    public init(width: Int, height: Int, fill: RGB) {
        let c = Self.bytes(fill)
        var d = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: d.count, by: 4) {
            d[i] = c.0
            d[i + 1] = c.1
            d[i + 2] = c.2
        }
        self.init(width: width, height: height, data: d)
    }

    /// Copies a BGRA capture buffer (ScreenCaptureKit's `kCVPixelFormatType_32BGRA`).
    public init?(bgra buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let src = base.assumingMemoryBound(to: UInt8.self)
        var d = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = y * stride + x * 4, o = (y * w + x) * 4
                d[o] = src[s + 2]
                d[o + 1] = src[s + 1]
                d[o + 2] = src[s]
                d[o + 3] = src[s + 3]
            }
        }
        self.init(width: w, height: h, data: d)
    }

    public func pixel(_ x: Int, _ y: Int) -> Pixel {
        let i = (y * width + x) * 4
        return Pixel(r: data[i], g: data[i + 1], b: data[i + 2], a: data[i + 3])
    }

    public mutating func fill(_ rect: CGRect, with c: RGB) {
        let b = Self.bytes(c)
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull else { return }
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) {
                let i = (y * width + x) * 4
                data[i] = b.0
                data[i + 1] = b.1
                data[i + 2] = b.2
                data[i + 3] = 255
            }
        }
    }

    /// Up to `grid × grid` evenly spaced pixels from `rect` (top-left pixel coordinates).
    public func sample(_ rect: CGRect, grid: Int = 12) -> BackgroundSample {
        let r = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return BackgroundSample(colors: []) }
        var colors: [RGB] = []
        colors.reserveCapacity(grid * grid)
        for gy in 0..<grid {
            for gx in 0..<grid {
                let x = Int(r.minX + (Double(gx) + 0.5) * r.width / Double(grid))
                let y = Int(r.minY + (Double(gy) + 0.5) * r.height / Double(grid))
                colors.append(pixel(min(x, width - 1), min(y, height - 1)).rgb)
            }
        }
        return BackgroundSample(colors: colors)
    }

    public var cgImage: CGImage {
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    public var ciImage: CIImage { CIImage(cgImage: cgImage) }

    static func bytes(_ c: RGB) -> (UInt8, UInt8, UInt8) {
        let k = c.clamped()
        return (UInt8((k.r * 255).rounded()), UInt8((k.g * 255).rounded()), UInt8((k.b * 255).rounded()))
    }
}
