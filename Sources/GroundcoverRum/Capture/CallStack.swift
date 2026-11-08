import Foundation

/// The frames of the calling thread's stack, for a handled error that carries none of its own (a
/// Swift `Error` has no stack): `{filename: the binary image, function: where in it}`, line and
/// column 0, the shape the engine writes a crash's frames in. Where in it is Apple's form, as
/// `backtrace_symbols` writes it: the symbol and the offset into it, else the image and the offset
/// into it, else the address. A stripped app's own code has no symbol at all, and the offset into
/// its image is what the build's dSYM resolves. The SDK's own frames, which open the stack, are
/// left out by place before `addresses` gets here, by the capture point that read them. At most
/// ``maxFrames``.
enum CallStack {
    static let maxFrames = 200

    static func frames(_ addresses: [NSNumber]) -> [ErrorFrame] {
        var frames: [ErrorFrame] = []
        for number in addresses {
            guard frames.count < maxFrames else { break }
            let address = UInt(truncating: number)
            var info = Dl_info()
            let found = dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0
            let symbol = found && info.dli_sname != nil ? String(cString: info.dli_sname) : ""
            let image =
                found && info.dli_fname != nil
                ? (String(cString: info.dli_fname) as NSString).lastPathComponent : ""
            let function =
                !symbol.isEmpty
                ? "\(symbol) + \(hex(address &- UInt(bitPattern: info.dli_saddr)))"
                : !image.isEmpty
                    ? "\(image) + \(hex(address &- UInt(bitPattern: info.dli_fbase)))"
                    : hex(address)
            frames.append(
                ErrorFrame(
                    filename: image.isEmpty ? "<unknown>" : image, function: function,
                    lineno: 0, colno: 0))
        }
        return frames
    }

    private static func hex(_ value: UInt) -> String {
        "0x" + String(value, radix: 16)
    }
}
