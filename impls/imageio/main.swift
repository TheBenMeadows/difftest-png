// Apple Image I/O, the decoder behind Preview, Safari, Finder and every app that opens a PNG through
// CGImageSource. The samples written are the CGImage's own backing bytes as Image I/O decoded them, read
// through its data provider: nothing is drawn into a bitmap context, so no color matching, no
// premultiplication and no depth change is applied on the way out.
import CoreGraphics
import Foundation
import ImageIO

func emit(_ line: String) { FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!) }
func fail(_ msg: String) -> Never { emit("ERR \(msg)"); exit(1) }
func shimFail(_ msg: String) -> Never { emit("SHIM \(msg)"); exit(70) }
// The library returned without error, but not an image the shim can write: its result.
func apiFail(_ msg: String) -> Never { emit("API \(msg)"); exit(71) }

let statusNames: [CGImageSourceStatus: String] = [
    .statusUnexpectedEOF: "unexpected end of file", .statusInvalidData: "invalid data",
    .statusUnknownType: "unknown type", .statusReadingHeader: "reading header",
    .statusIncomplete: "incomplete", .statusComplete: "complete",
]

let args = CommandLine.arguments
if args.count == 2 && args[1] == "--version" {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    emit("Apple Image I/O (macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion))")
    exit(0)
}
guard args.count == 3 else { shimFail("usage: shim in.png out.pam") }
guard let data = FileManager.default.contents(atPath: args[1]) else { shimFail("cannot read \(args[1])") }

// The type hint keeps a PNG from being sniffed as some other format. Image I/O decodes lazily by default and
// a decoding failure then surfaces only when the pixels are first read; decoding at creation puts the
// failure where the shim can report it as one.
let opts = [kCGImageSourceTypeIdentifierHint: "public.png", kCGImageSourceShouldCacheImmediately: true] as CFDictionary
guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { fail("CGImageSourceCreateWithData returned nil") }
if let t = CGImageSourceGetType(src) { emit("INFO type=\(t)") }
let whole = CGImageSourceGetStatus(src)
guard CGImageSourceGetCount(src) > 0 else { fail("no images (source status: \(statusNames[whole] ?? "\(whole.rawValue)"))") }
guard let img = CGImageSourceCreateImageAtIndex(src, 0, opts) else {
    fail("CGImageSourceCreateImageAtIndex returned nil (status: \(statusNames[CGImageSourceGetStatusAtIndex(src, 0)] ?? "?"))")
}
// Preview and Safari display what CGImageSourceCreateImageAtIndex returns; a status short of complete is
// reported, not turned into a rejection the system itself does not make.
let status = CGImageSourceGetStatusAtIndex(src, 0)
if status != .statusComplete { emit("WARN image status: \(statusNames[status] ?? "\(status.rawValue)")") }

let w = img.width, h = img.height
let bpc = img.bitsPerComponent, bpp = img.bitsPerPixel, stride = img.bytesPerRow
let info = img.bitmapInfo
let alpha = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) ?? .none
let order = info.rawValue & CGBitmapInfo.byteOrderMask.rawValue
guard let space = img.colorSpace else { apiFail("image has no color space") }
emit("INFO width=\(w) height=\(h) bpc=\(bpc) bpp=\(bpp) alpha=\(alpha.rawValue) order=\(order) model=\(space.model.rawValue) float=\(info.contains(.floatComponents))")
guard w > 0, h > 0 else { apiFail("decoded size \(w)x\(h)") }
guard !info.contains(.floatComponents) else { apiFail("float components") }
guard alpha != .premultipliedLast, alpha != .premultipliedFirst else { apiFail("premultiplied alpha returned") }
// A CGImage whose provider yields no bytes is how a failed decode shows itself: the system draws nothing.
guard let provided = img.dataProvider?.data as Data? else { fail("decoding failed: the image's data provider returned no pixels") }
guard provided.count >= stride * (h - 1) + (bpp * w + 7) / 8 else { apiFail("pixel data shorter than \(h) rows") }

// Channel layout of one pixel as stored: which stored channel is gray/red/green/blue/alpha, and padding.
let indexed = space.model == .indexed
let colors = indexed ? 1 : space.numberOfComponents
let hasAlpha = alpha == .last || alpha == .first
let padded = alpha == .noneSkipLast || alpha == .noneSkipFirst
let stored = colors + (hasAlpha || padded ? 1 : 0)
guard bpp == stored * bpc else { apiFail("\(bpp) bits per pixel for \(stored) channels of \(bpc) bits") }
guard [1, 2, 4, 8, 16].contains(bpc) else { apiFail("\(bpc) bits per component") }
guard indexed || colors == 1 || colors == 3 else { apiFail("color space with \(colors) components") }
let first = alpha == .first || alpha == .noneSkipFirst  // the extra channel leads the pixel
let little = (bpc == 16 && order == CGBitmapInfo.byteOrder16Little.rawValue)
    || (bpc == 8 && order == CGBitmapInfo.byteOrder32Little.rawValue)
guard !(bpc == 8 && order == CGBitmapInfo.byteOrder32Little.rawValue && stored != 4) else { apiFail("32-bit little-endian order on \(stored) channels") }

var table: [UInt8] = []
if indexed {
    table = space.colorTable ?? []
    guard space.baseColorSpace?.model == .rgb else { apiFail("indexed image whose base space is not RGB") }
    guard bpc <= 8 else { apiFail("indexed image with \(bpc)-bit indices") }
}

// Output: palette expands to RGB, or RGBA when the image carries alpha (a tRNS on a palette image arrives as
// an alpha channel beside the index); sub-byte gray keeps its own maxval, one byte per sample.
let outChannels = indexed ? (hasAlpha ? 4 : 3) : colors + (hasAlpha ? 1 : 0)
let outDepth = bpc == 16 ? 16 : 8
let maxval = indexed ? 255 : (1 << bpc) - 1
let tupl = ["GRAYSCALE", "GRAYSCALE_ALPHA", "RGB", "RGB_ALPHA"][outChannels - 1]
guard FileManager.default.createFile(atPath: args[2], contents: nil), let out = FileHandle(forWritingAtPath: args[2]) else {
    shimFail("cannot create \(args[2])")
}
out.write("P7\nWIDTH \(w)\nHEIGHT \(h)\nDEPTH \(outChannels)\nMAXVAL \(maxval)\nTUPLTYPE \(tupl)\nENDHDR\n".data(using: .ascii)!)

// A palette index past the end of the color table has no color in the data Image I/O returns; what the system
// shows for it is what Core Graphics draws. For an opaque indexed image that is read by drawing it once into an
// RGB bitmap in the palette's own base space (so no color matching), at its own size (so no interpolation).
var drawn: [UInt8]? = nil
if indexed && bpc <= 8 {
    let entries = table.count / 3
    let tooHigh = provided.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        let p = raw.bindMemory(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let bit = (x * stored + (first ? 1 : 0)) * bpc
                let byte = Int(p[y * stride + bit / 8])
                let i = bpc == 8 ? byte : (byte >> (8 - bpc - bit % 8)) & ((1 << bpc) - 1)
                if i >= entries { return true }
            }
        }
        return false
    }
    if tooHigh {
        guard !hasAlpha else { apiFail("palette index past the color table on an image with alpha") }
        guard let base = space.baseColorSpace,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: base,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { shimFail("cannot make an RGB bitmap") }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data else { shimFail("bitmap has no data") }
        drawn = Array(UnsafeBufferPointer(start: buf.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        emit("INFO palette index past the \(entries)-entry table; colors taken from Core Graphics drawing")
    }
}

if let d = drawn {
    // Rows of the bitmap run top to bottom, as the PAM's do.
    for y in 0..<h {
        var row = [UInt8](repeating: 0, count: w * 3)
        for x in 0..<w { for c in 0..<3 { row[x * 3 + c] = d[(y * w + x) * 4 + c] } }
        out.write(Data(row))
    }
    out.closeFile()
    emit("OK \(w) \(h) 3 8")
    exit(0)
}

provided.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    let p = raw.bindMemory(to: UInt8.self)
    var row = [UInt8](repeating: 0, count: w * outChannels * (outDepth / 8))
    for y in 0..<h {
        let base = y * stride
        var o = 0
        for x in 0..<w {
            // Stored sample k of pixel x, as an integer of bpc bits.
            func sample(_ k: Int) -> Int {
                if bpc == 16 {
                    let at = base + (x * stored + k) * 2
                    let a = Int(p[at]), b = Int(p[at + 1])
                    return little ? (b << 8 | a) : (a << 8 | b)
                }
                if bpc == 8 {
                    var kk = k
                    if little { kk = stored - 1 - k }  // 32-bit little-endian: bytes reversed within the pixel
                    return Int(p[base + x * stored + kk])
                }
                let bit = (x * stored + k) * bpc
                let byte = Int(p[base + bit / 8])
                return (byte >> (8 - bpc - bit % 8)) & ((1 << bpc) - 1)
            }
            let c0 = first ? 1 : 0
            let a = hasAlpha ? sample(first ? 0 : stored - 1) : -1
            var put: [Int]
            if indexed {
                let i = sample(c0)
                guard i < table.count / 3 else { apiFail("palette index \(i) past a \(table.count / 3)-entry table") }
                put = [Int(table[i * 3]), Int(table[i * 3 + 1]), Int(table[i * 3 + 2])]
                if hasAlpha { put.append(bpc == 8 ? a : a * 255 / ((1 << bpc) - 1)) }
            } else {
                put = (0..<colors).map { sample(c0 + $0) }
                if hasAlpha { put.append(a) }
            }
            for v in put {
                if outDepth == 16 { row[o] = UInt8(v >> 8); row[o + 1] = UInt8(v & 255); o += 2 } else { row[o] = UInt8(v); o += 1 }
            }
        }
        out.write(Data(row))
    }
}
out.closeFile()
emit("OK \(w) \(h) \(outChannels) \(outDepth)")
