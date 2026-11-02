import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An 8-bit RGBA picture in sRGB, one pixel per CSS pixel.
struct RGBAImage: Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// `image` drawn at exactly `width`×`height` (a Retina snapshot is scaled down to CSS pixels).
    init?(_ image: CGImage, width: Int, height: Int) {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    init?(png: Data) {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.init(img, width: img.width, height: img.height)
    }

    func png() -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// The mean colour of tile (`tx`, `ty`), `tile` pixels square, clipped to the picture.
    func tileMean(_ tile: Int, _ tx: Int, _ ty: Int) -> (Double, Double, Double) {
        var sum = (0, 0, 0), n = 0
        for y in (ty * tile)..<min((ty + 1) * tile, height) {
            for x in (tx * tile)..<min((tx + 1) * tile, width) {
                let o = (y * width + x) * 4
                sum.0 += Int(pixels[o]); sum.1 += Int(pixels[o + 1]); sum.2 += Int(pixels[o + 2])
                n += 1
            }
        }
        let d = Double(max(n, 1))
        return (Double(sum.0) / d, Double(sum.1) / d, Double(sum.2) / d)
    }
}

/// The parts of a page that change by themselves (carousels, videos, animations), one bit per
/// 16 px tile, found by photographing the page more than once. The same rule as the engine's
/// `NoiseMask`, so `noise-<width>.png` means the same thing whichever browser wrote it.
struct NoiseMask: Equatable {
    static let tile = 16
    let cols: Int
    let rows: Int
    var bits: [Bool]

    /// Tiles whose mean colour differs by more than `threshold` in any channel, grown by one tile
    /// so a moving edge is covered too.
    init(between a: RGBAImage, _ b: RGBAImage, threshold: Double) {
        let t = Self.tile
        let (w, h) = (min(a.width, b.width), min(a.height, b.height))
        let (cols, rows) = ((w + t - 1) / t, (h + t - 1) / t)
        var changed = [Bool](repeating: false, count: cols * rows)
        for ty in 0..<rows {
            for tx in 0..<cols {
                let (x, y) = (a.tileMean(t, tx, ty), b.tileMean(t, tx, ty))
                changed[ty * cols + tx] = abs(x.0 - y.0) > threshold || abs(x.1 - y.1) > threshold || abs(x.2 - y.2) > threshold
            }
        }
        var bits = [Bool](repeating: false, count: cols * rows)
        for ty in 0..<rows {
            for tx in 0..<cols {
                bits[ty * cols + tx] = (-1...1).contains { dy in
                    (-1...1).contains { dx in
                        let (x, y) = (tx + dx, ty + dy)
                        return x >= 0 && y >= 0 && x < cols && y < rows && changed[y * cols + x]
                    }
                }
            }
        }
        self.cols = cols
        self.rows = rows
        self.bits = bits
    }

    /// The tiles either mask covers (two masks of the same page).
    func union(_ other: NoiseMask) -> NoiseMask {
        guard (cols, rows) == (other.cols, other.rows) else { return self }
        var out = self
        out.bits = zip(bits, other.bits).map { $0 || $1 }
        return out
    }

    var count: Int { bits.filter { $0 }.count }

    /// One pixel per tile, white where the page changes by itself.
    func png() -> Data? {
        let pixels = bits.flatMap { $0 ? [UInt8](repeating: 255, count: 4) : [0, 0, 0, 255] }
        return RGBAImage(width: max(cols, 1), height: max(rows, 1), pixels: pixels.isEmpty ? [0, 0, 0, 255] : pixels).png()
    }
}
