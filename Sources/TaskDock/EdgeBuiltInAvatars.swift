import Foundation

/// Edge stores its built-in profile illustrations as Chromium vector icons in its framework.
/// Read the asset data from the installed browser without loading the framework as code.
enum EdgeBuiltInAvatars {
    static func frameworkURL(in application: URL) -> URL {
        application.appendingPathComponent(
            "Contents/Frameworks/Microsoft Edge Framework.framework/Versions/Current/Microsoft Edge Framework"
        ).resolvingSymlinksInPath()
    }

    static func load(from framework: URL) -> [Int: Data] {
        guard let data = try? Data(contentsOf: framework, options: .mappedIfSafe),
              let image = FrameworkImage(data: data),
              let plantName = image.find(Data("kPlantAvatarIcon\0".utf8), in: image.text) else { return [:] }

        // A VectorIcon contains a span of representations followed by its C-string name.
        // The Edge profile table has a 24-byte entry for each avatar, including index 40 (Plant).
        let plantIndex = 40
        let stride = 24
        for nameReference in image.references(to: plantName) {
            let plantIcon = nameReference - 16
            guard image.iconName(at: plantIcon) == "kPlantAvatarIcon" else { continue }
            for plantEntry in image.references(to: plantIcon) {
                let start = plantEntry - stride * plantIndex
                guard start >= image.constants.lowerBound,
                      image.iconName(at: image.pointer(at: start + stride * 22)) == "kDogAvatarIcon",
                      image.iconName(at: image.pointer(at: start + stride * 25)) == "kAstronautAvatarIcon",
                      image.iconName(at: image.pointer(at: start + stride * 27)) == "kYetiAvatarIcon" else { continue }
                var avatars: [Int: Data] = [:]
                for index in 1...plantIndex {
                    let icon = image.pointer(at: start + stride * index)
                    guard let name = image.iconName(at: icon), name.hasSuffix("AvatarIcon"),
                          let path = image.pathElements(for: icon),
                          let svg = ProfileVectorSVG.render(path) else { continue }
                    avatars[index] = svg
                }
                return avatars
            }
        }
        return [:]
    }

    private struct FrameworkImage {
        let data: Data
        let base: Int
        let text: Range<Int>
        let constants: Range<Int>

        init?(data: Data) {
            let magic = data.integer(at: 0, as: UInt32.self)
            let base: Int
            if magic == 0xbeba_feca {
                let count = Int(data.integer(at: 4, as: UInt32.self).bigEndian)
                guard (1...16).contains(count) else { return nil }
                let slices = (0..<count).map { 8 + $0 * 20 }
                let architecture = slices.first {
                    data.integer(at: $0, as: UInt32.self).bigEndian == 0x0100_000c
                } ?? slices.first {
                    data.integer(at: $0, as: UInt32.self).bigEndian == 0x0100_0007
                }
                guard let architecture else { return nil }
                base = Int(data.integer(at: architecture + 8, as: UInt32.self).bigEndian)
            } else {
                base = 0
            }
            guard data.integer(at: base, as: UInt32.self) == 0xfeed_facf else { return nil }
            let count = Int(data.integer(at: base + 16, as: UInt32.self))
            guard (1...256).contains(count) else { return nil }
            var segments: [String: Range<Int>] = [:]
            var position = base + 32
            for _ in 0..<count {
                let command = data.integer(at: position, as: UInt32.self)
                let length = Int(data.integer(at: position + 4, as: UInt32.self))
                guard length >= 8, position <= data.count - length else { return nil }
                if command == 0x19, length >= 72 {
                    let name = String(decoding: data[(position + 8)..<(position + 24)].prefix { $0 != 0 }, as: UTF8.self)
                    let offset = data.integer(at: position + 40, as: UInt64.self)
                    let size = data.integer(at: position + 48, as: UInt64.self)
                    let address = data.integer(at: position + 24, as: UInt64.self)
                    if offset == address, offset <= UInt64(data.count - base),
                       size <= UInt64(data.count - base) - offset {
                        segments[name] = Int(offset)..<Int(offset + size)
                    }
                }
                position += length
            }
            guard let text = segments["__TEXT"], let constants = segments["__DATA_CONST"] else { return nil }
            self.data = data
            self.base = base
            self.text = text
            self.constants = constants
        }

        func pointer(at offset: Int) -> Int {
            guard offset >= 0 else { return 0 }
            let value = data.integer(at: base + offset, as: UInt64.self)
            // DYLD_CHAINED_PTR_64_OFFSET stores the rebase target in the low 36 bits.
            return Int(value & 0x0000_000f_ffff_ffff)
        }

        func find(_ bytes: Data, in range: Range<Int>) -> Int? {
            data.range(of: bytes, in: (base + range.lowerBound)..<(base + range.upperBound))
                .map { $0.lowerBound - base }
        }

        func references(to target: Int) -> [Int] {
            guard let address = UInt32(exactly: target) else { return [] }
            var littleEndianAddress = address.littleEndian
            let bytes = withUnsafeBytes(of: &littleEndianAddress) { Data($0) }
            var matches: [Int] = []
            var next = constants.lowerBound
            while let match = find(bytes, in: next..<constants.upperBound) {
                if match.isMultiple(of: 8), pointer(at: match) == target { matches.append(match) }
                next = match + 1
            }
            return matches
        }

        func iconName(at offset: Int) -> String? {
            guard constants.contains(offset), offset <= constants.upperBound - 24,
                  (1...8).contains(data.integer(at: base + offset + 8, as: UInt64.self)),
                  constants.contains(pointer(at: offset)) else { return nil }
            let start = pointer(at: offset + 16)
            guard text.contains(start) else { return nil }
            let range = (base + start)..<(base + min(start + 64, text.upperBound))
            guard let end = data[range].firstIndex(of: 0) else { return nil }
            return String(data: data[range.lowerBound..<end], encoding: .ascii)
        }

        func pathElements(for icon: Int) -> [UInt32]? {
            let representation = pointer(at: icon)
            guard constants.contains(representation), representation <= constants.upperBound - 16 else { return nil }
            let count = data.integer(at: base + representation + 8, as: UInt64.self)
            let path = pointer(at: representation)
            guard (2...10_000).contains(count), text.contains(path),
                  count <= UInt64((text.upperBound - path) / 4) else { return nil }
            return (0..<Int(count)).map { data.integer(at: base + path + $0 * 4, as: UInt32.self) }
        }
    }
}

private extension Data {
    func integer<T: FixedWidthInteger>(at index: Int, as type: T.Type) -> T {
        guard index >= 0, index <= count - MemoryLayout<T>.size else { return 0 }
        return withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: index, as: type)) }
    }
}

/// The command order and argument counts follow Chromium's vector_icon_types.h and vector_icon_utils.cc.
/// SVG lets AppKit render the paths without embedding Edge artwork or a second graphics engine.
private enum ProfileVectorSVG {
    private static let argumentCounts = [
        0, 0, 1, 4, 0, 1, 0, 2, 2, 7, 7, 2, 2, 1, 1, 1, 1, 6, 6, 4, 4, 4, 2, 2, 3, 4, 5, 0, 1, 4, 0, 0,
    ]
    private static let pathCommands: [Int: String] = [
        7: "M", 8: "m", 9: "A", 10: "a", 11: "L", 12: "l", 13: "H", 14: "h",
        15: "V", 16: "v", 17: "C", 18: "c", 19: "S", 20: "Q", 21: "q", 22: "T", 23: "t", 27: "Z",
    ]

    static func render(_ elements: [UInt32]) -> Data? {
        guard elements.first == 28, elements.count > 2 else { return nil }
        let canvas = Float(bitPattern: elements[1])
        guard canvas.isFinite, (8...512).contains(canvas) else { return nil }
        var cursor = 0
        var drawing = ""
        var shapes: [String] = []
        var path = ""
        var color = "black"
        var opacity: Float = 1
        var fillRule = "evenodd"
        var stroke: Float?
        var lineCap = "round"
        func flush() {
            if !path.isEmpty { shapes.append("<path d=\"\(path)\"/>") }
            if !shapes.isEmpty {
                let paint = stroke.map { "fill=\"none\" stroke=\"\(color)\" stroke-width=\"\($0)\" stroke-linecap=\"\(lineCap)\"" }
                    ?? "fill=\"\(color)\" fill-rule=\"\(fillRule)\""
                drawing += "<g \(paint) opacity=\"\(opacity)\">\(shapes.joined())</g>"
            }
            shapes.removeAll(keepingCapacity: true)
            path = ""
            color = "black"
            opacity = 1
            fillRule = "evenodd"
            stroke = nil
            lineCap = "round"
        }
        while cursor < elements.count {
            let command = Int(elements[cursor])
            guard argumentCounts.indices.contains(command) else { return nil }
            let next = cursor + 1 + argumentCounts[command]
            guard next <= elements.count else { return nil }
            let args = elements[(cursor + 1)..<next].map { Float(bitPattern: $0) }
            guard args.allSatisfy({ $0.isFinite && abs($0) < 100_000 }) else { return nil }
            cursor = next
            if let operation = pathCommands[command] {
                let values = args.enumerated().map { index, value in
                    ((command == 9 || command == 10) && (index == 3 || index == 4))
                        ? (value == 0 ? "0" : "1") : String(value)
                }
                path += operation + values.joined(separator: " ") + " "
                continue
            }
            switch command {
            case 0: flush()
            case 1: fillRule = "nonzero"
            case 2: opacity = min(1, max(0, args[0] / 255))
            case 3:
                let rgb = args.dropFirst().map { String(Int(min(255, max(0, $0)))) }.joined(separator: ",")
                color = "rgb(\(rgb))"
                opacity = min(1, max(0, args[0] / 255))
            case 4: return nil
            case 5: stroke = args[0]
            case 6: lineCap = "square"
            case 24: shapes.append("<circle cx=\"\(args[0])\" cy=\"\(args[1])\" r=\"\(args[2])\"/>")
            case 25:
                shapes.append("<ellipse cx=\"\(args[0])\" cy=\"\(args[1])\" rx=\"\(args[2])\" ry=\"\(args[3])\"/>")
            case 26:
                shapes.append("<rect x=\"\(args[0])\" y=\"\(args[1])\" width=\"\(args[2])\" height=\"\(args[3])\" rx=\"\(args[4])\"/>")
            case 28, 30, 31: break
            default: return nil
            }
        }
        flush()
        guard !drawing.isEmpty else { return nil }
        return Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 \(canvas) \(canvas)">\(drawing)</svg>
        """.utf8)
    }
}
