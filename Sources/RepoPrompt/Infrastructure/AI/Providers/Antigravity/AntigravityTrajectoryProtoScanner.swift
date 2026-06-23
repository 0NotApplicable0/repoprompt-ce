import Foundation

/// Minimal reader for length-delimited (wire type 2) protobuf fields. agy stores each trajectory
/// `step_payload` as nested protobuf; callers invoke this once per level to descend. Skips other
/// wire types so unknown fields don't derail it. Fail-open: malformed input stops the scan and
/// returns what was read.
enum AntigravityTrajectoryProtoScanner {
    static func lengthDelimitedFields(_ data: Data) -> [Int: Data] {
        let bytes = [UInt8](data)
        var result: [Int: Data] = [:]
        var i = 0
        while i < bytes.count {
            guard let (tag, afterTag) = readVarint(bytes, i) else { break }
            i = afterTag
            let field = Int(tag >> 3)
            switch Int(tag & 0x7) {
            case 0: // varint
                guard let (_, n) = readVarint(bytes, i) else { return result }
                i = n
            case 2: // length-delimited
                guard let (len, n) = readVarint(bytes, i) else { return result }
                let start = n, stop = start + Int(len)
                guard len <= UInt64(bytes.count), stop >= start, stop <= bytes.count else { return result }
                if result[field] == nil { result[field] = Data(bytes[start ..< stop]) }
                i = stop
            case 5: i += 4
                if i > bytes.count { return result } // 32-bit
            case 1: i += 8
                if i > bytes.count { return result } // 64-bit
            default: return result // groups / unknown — stop, fail-open
            }
        }
        return result
    }

    private static func readVarint(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0, shift: UInt64 = 0, i = start
        while i < bytes.count {
            let byte = bytes[i]
            i += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (value, i) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
