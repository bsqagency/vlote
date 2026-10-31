import Foundation
import CoreGraphics

// Unit checks for the Full Page feature: PDF page cuts and the stitcher.
// Compiled with test.sh (fptests). Top-level code: keep this the only main file in the binary.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("  FAIL: \(message)") }
}

// ---- Helpers ----

/// Solid-colour CGImage (sRGB), `width` × `height` pixels.
func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// RGB of every row (top row first), read from the image's own pixels.
func rowColors(of image: CGImage) -> [(r: Int, g: Int, b: Int)] {
    let w = image.width, h = image.height
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    // Memory row 0 is the top of the drawn image.
    return (0..<h).map { row in
        let i = (row * w + w / 2) * 4   // centre column
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
    }
}

func isColor(_ c: (r: Int, g: Int, b: Int), _ r: Int, _ g: Int, _ b: Int) -> Bool {
    abs(c.r - r) <= 8 && abs(c.g - g) <= 8 && abs(c.b - b) <= 8
}

// ---- PDFExport.pageCuts(rowMeans:pageHeight:) ----
let white = 255.0
let ink = 40.0

// Text row sits right at the 500 boundary; a blank row 10 px above it at 490.
var means = [Double](repeating: ink, count: 2000)
for row in 0..<2000 where row % 50 == 0 { means[row] = white }   // blank rows every 50 px
for row in 480...520 { means[row] = ink }                        // text band around the boundary
means[490] = white                                               // the one blank row in the band
check(PDFExport.pageCuts(rowMeans: means, pageHeight: 500) == [490, 1000, 1500],
      "cut should move to the blank row 490 (got \(PDFExport.pageCuts(rowMeans: means, pageHeight: 500)))")

// Blank row only 130 px above the boundary: outside the 120 px search, so fall back to the boundary.
var far = [Double](repeating: ink, count: 1200)
far[370] = white
check(PDFExport.pageCuts(rowMeans: far, pageHeight: 500) == [500, 1000],
      "no blank row within 120 px should cut at the boundary")

// No blank rows at all: every cut is on its boundary.
let solid = [Double](repeating: ink, count: 2000)
check(PDFExport.pageCuts(rowMeans: solid, pageHeight: 500) == [500, 1000, 1500],
      "text-only image should cut on every boundary")

// Image that fits on one page: no cuts.
check(PDFExport.pageCuts(rowMeans: [Double](repeating: ink, count: 400), pageHeight: 500).isEmpty,
      "image shorter than a page should need no cuts")

// Cuts must always go up, never past the previous cut.
let cuts = PDFExport.pageCuts(rowMeans: means, pageHeight: 500)
check(zip([0] + cuts, cuts).allSatisfy { $0 < $1 }, "cuts must be strictly ascending")

// ---- Stitcher.stitch ----
// Three 100 px slices at scrollY 0, 80, 160 (overlap 20 px), total 260 px, dpr 1.
let red = solidImage(width: 10, height: 100, red: 1, green: 0, blue: 0)
let green = solidImage(width: 10, height: 100, red: 0, green: 1, blue: 0)
let blue = solidImage(width: 10, height: 100, red: 0, green: 0, blue: 1)
let slices = [
    CapturedSlice(image: red, scrollY: 0),
    CapturedSlice(image: green, scrollY: 80),
    CapturedSlice(image: blue, scrollY: 160),
]

do {
    let out = try Stitcher.stitch(slices, totalHeight: 260, dpr: 1)
    check(out.height == 260, "stitched height should be 260, got \(out.height)")
    check(out.width == 10, "stitched width should be 10, got \(out.width)")

    let rows = rowColors(of: out)
    let reds = rows.filter { isColor($0, 255, 0, 0) }.count
    let greens = rows.filter { isColor($0, 0, 255, 0) }.count
    let blues = rows.filter { isColor($0, 0, 0, 255) }.count
    check(reds == 100, "red (first slice) should fill 100 rows, got \(reds)")
    check(greens == 80, "green should fill 80 new rows after the overlap, got \(greens)")
    check(blues == 80, "blue should fill 80 new rows after the overlap, got \(blues)")
    check(reds + greens + blues == 260, "every row should be one slice colour")

    // Order: red above green above blue, with no interleaving.
    if rows.count == 260 {
        check(isColor(rows[0], 255, 0, 0) && isColor(rows[99], 255, 0, 0), "rows 0–99 should be red")
        check(isColor(rows[100], 0, 255, 0) && isColor(rows[179], 0, 255, 0), "rows 100–179 should be green")
        check(isColor(rows[180], 0, 0, 255) && isColor(rows[259], 0, 0, 255), "rows 180–259 should be blue")
    }
} catch {
    failures += 1; print("  FAIL: stitch threw \(error)")
}

// Overlap keeps the first slice: a later slice must not cover rows already drawn.
do {
    let out = try Stitcher.stitch(slices, totalHeight: 260, dpr: 1)
    let rows = rowColors(of: out)
    check(isColor(rows[90], 255, 0, 0), "row 90 (inside the first overlap) should stay red")
} catch {
    failures += 1; print("  FAIL: stitch threw \(error)")
}

// Empty input is an error, not a crash.
do {
    _ = try Stitcher.stitch([], totalHeight: 100, dpr: 1)
    check(false, "empty slice list should throw")
} catch {
    // expected
}

print(failures == 0 ? "All full-page checks passed" : "\(failures) full-page checks FAILED")
exit(failures == 0 ? 0 : 1)
