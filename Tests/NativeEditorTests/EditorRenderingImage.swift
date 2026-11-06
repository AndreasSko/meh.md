import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A rendered part of the editor, addressed in the text view's coordinates.
struct EditorRenderingImage {
    struct Color: Equatable {
        var red: Int, green: Int, blue: Int

        /// The largest difference in any channel, 0...255.
        func distance(to other: Color) -> Int {
            max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
        }
    }

    /// Touching pixels that differ from the paper, in view coordinates.
    struct Component {
        var bounds: CGRect
        var center: CGPoint
        var pixelCount: Int
    }

    let image: CGImage
    /// The view point at the image's top left corner.
    let origin: CGPoint
    let scale: CGFloat
    let paper: Color
    private let pixels: [UInt8]
    var width: Int { image.width }
    var height: Int { image.height }

    init(image: CGImage, origin: CGPoint, scale: CGFloat, paper: CGColor) {
        self.image = image
        self.origin = origin
        self.scale = scale
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        // The array's pointer is valid only inside this closure.
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        pixels = bytes
        let srgb = paper.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        )?.components ?? [1, 1, 1, 1]
        self.paper = Color(
            red: Int((srgb[0] * 255).rounded()),
            green: Int((srgb[1] * 255).rounded()),
            blue: Int((srgb[2] * 255).rounded())
        )
    }

    func color(x: Int, y: Int) -> Color {
        let index = (y * width + x) * 4
        return Color(
            red: Int(pixels[index]), green: Int(pixels[index + 1]), blue: Int(pixels[index + 2])
        )
    }

    func pixelX(_ x: CGFloat) -> Int { Int(((x - origin.x) * scale).rounded(.down)) }
    func pixelY(_ y: CGFloat) -> Int { Int(((y - origin.y) * scale).rounded(.down)) }
    func pointY(_ y: Int) -> CGFloat { CGFloat(y) / scale + origin.y }

    /// The pixel columns and rows a rect covers, clipped to the image.
    func pixels(in rect: CGRect) -> (x: Range<Int>, y: Range<Int>) {
        let minX = max(0, pixelX(rect.minX)), maxX = min(width, pixelX(rect.maxX))
        let minY = max(0, pixelY(rect.minY)), maxY = min(height, pixelY(rect.maxY))
        return (minX..<max(minX, maxX), minY..<max(minY, maxY))
    }

    func isInk(x: Int, y: Int, threshold: Int) -> Bool {
        color(x: x, y: y).distance(to: paper) >= threshold
    }

    /// Groups of touching pixels at least `threshold` away from the paper.
    func components(in rect: CGRect, threshold: Int) -> [Component] {
        let area = pixels(in: rect)
        guard !area.x.isEmpty, !area.y.isEmpty else { return [] }
        let columns = area.x.count
        var seen = [Bool](repeating: false, count: columns * area.y.count)
        var result: [Component] = []
        for startY in area.y {
            for startX in area.x {
                let startIndex = (startY - area.y.lowerBound) * columns + startX - area.x.lowerBound
                guard !seen[startIndex], isInk(x: startX, y: startY, threshold: threshold)
                else { continue }
                seen[startIndex] = true
                var stack = [(startX, startY)]
                var count = 0, sumX = 0, sumY = 0
                var minX = startX, maxX = startX, minY = startY, maxY = startY
                while let (x, y) = stack.popLast() {
                    count += 1
                    sumX += x
                    sumY += y
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    for (nextX, nextY) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
                    where area.x.contains(nextX) && area.y.contains(nextY) {
                        let index = (nextY - area.y.lowerBound) * columns
                            + nextX - area.x.lowerBound
                        if !seen[index], isInk(x: nextX, y: nextY, threshold: threshold) {
                            seen[index] = true
                            stack.append((nextX, nextY))
                        }
                    }
                }
                result.append(Component(
                    bounds: CGRect(
                        x: CGFloat(minX) / scale + origin.x,
                        y: CGFloat(minY) / scale + origin.y,
                        width: CGFloat(maxX - minX + 1) / scale,
                        height: CGFloat(maxY - minY + 1) / scale
                    ),
                    center: CGPoint(
                        x: (CGFloat(sumX) / CGFloat(count) + 0.5) / scale + origin.x,
                        y: (CGFloat(sumY) / CGFloat(count) + 0.5) / scale + origin.y
                    ),
                    pixelCount: count
                ))
            }
        }
        return result
    }

    /// The image with failing spots outlined, for a failure report.
    func png(marking rects: [CGRect]) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(red: 1, green: 0, blue: 0.3, alpha: 0.9)
        context.setLineWidth(max(1, scale))
        for rect in rects {
            // CGContext's origin is at the bottom; the image's rows start at the top.
            let x = (rect.minX - origin.x) * scale
            let y = CGFloat(height) - (rect.maxY - origin.y) * scale
            context.stroke(CGRect(
                x: x, y: y, width: rect.width * scale, height: rect.height * scale
            ).insetBy(dx: -2, dy: -2))
        }
        guard let marked = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, marked, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
