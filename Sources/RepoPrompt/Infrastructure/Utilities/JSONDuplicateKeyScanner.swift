import Foundation

/// Detects duplicate object keys without first collapsing the document into a dictionary.
///
/// Foundation accepts UTF-8, UTF-16, and UTF-32 JSON and silently keeps one value when an
/// object repeats a key. Callers that may rewrite user-owned JSON must therefore run this scanner
/// in addition to Foundation's normal syntax validation. Scanner failures throw so an encoding or
/// structural mismatch can never be interpreted as an unambiguous document.
enum JSONDuplicateKeyScanner {
    enum ScanError: Error {
        case malformedDocument
    }

    static func containsDuplicateKeys(in data: Data) throws -> Bool {
        let bytes = try canonicalUTF8Bytes(from: data)
        var scanner = Scanner(bytes: bytes)
        return try scanner.scanDocument()
    }

    private static func canonicalUTF8Bytes(from data: Data) throws -> [UInt8] {
        let bytes = Array(data)
        let encoding = detectedEncoding(in: bytes)
        let encodedPayload = Data(bytes.dropFirst(encoding.byteOrderMarkLength))
        guard let string = String(data: encodedPayload, encoding: encoding.stringEncoding) else {
            throw ScanError.malformedDocument
        }
        return Array(string.utf8)
    }

    private struct DetectedEncoding {
        let stringEncoding: String.Encoding
        let byteOrderMarkLength: Int
    }

    private static func detectedEncoding(in bytes: [UInt8]) -> DetectedEncoding {
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return DetectedEncoding(stringEncoding: .utf32BigEndian, byteOrderMarkLength: 4)
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return DetectedEncoding(stringEncoding: .utf32LittleEndian, byteOrderMarkLength: 4)
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return DetectedEncoding(stringEncoding: .utf8, byteOrderMarkLength: 3)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return DetectedEncoding(stringEncoding: .utf16BigEndian, byteOrderMarkLength: 2)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return DetectedEncoding(stringEncoding: .utf16LittleEndian, byteOrderMarkLength: 2)
        }

        // RFC 8259 requires UTF-8 for interoperable JSON, but Foundation also accepts unmarked
        // UTF-16/32 by inspecting the null-byte pattern in the opening code units. Mirror that
        // behavior so otherwise valid documents do not become scanner failures.
        if bytes.count >= 4 {
            switch (bytes[0], bytes[1], bytes[2], bytes[3]) {
            case (0, 0, 0, _):
                return DetectedEncoding(stringEncoding: .utf32BigEndian, byteOrderMarkLength: 0)
            case (_, 0, 0, 0):
                return DetectedEncoding(stringEncoding: .utf32LittleEndian, byteOrderMarkLength: 0)
            case (0, _, 0, _):
                return DetectedEncoding(stringEncoding: .utf16BigEndian, byteOrderMarkLength: 0)
            case (_, 0, _, 0):
                return DetectedEncoding(stringEncoding: .utf16LittleEndian, byteOrderMarkLength: 0)
            default:
                break
            }
        }
        return DetectedEncoding(stringEncoding: .utf8, byteOrderMarkLength: 0)
    }

    private struct Scanner {
        private let bytes: [UInt8]
        private var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func scanDocument() throws -> Bool {
            skipWhitespace()
            let duplicate = try scanValue()
            // A duplicate can short-circuit immediately. Requiring end-of-input after that point
            // would turn an already-proven ambiguity into a scanner failure.
            if duplicate { return true }
            skipWhitespace()
            guard index == bytes.count else { throw ScanError.malformedDocument }
            return false
        }

        private mutating func scanValue() throws -> Bool {
            skipWhitespace()
            guard let byte = currentByte else { throw ScanError.malformedDocument }
            switch byte {
            case UInt8(ascii: "{"):
                return try scanObject()
            case UInt8(ascii: "["):
                return try scanArray()
            case UInt8(ascii: "\""):
                _ = try scanString()
                return false
            default:
                try scanPrimitive()
                return false
            }
        }

        private mutating func scanObject() throws -> Bool {
            try consume(UInt8(ascii: "{"))
            skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "}")) { return false }

            var keys: Set<String> = []
            while true {
                skipWhitespace()
                let key = try scanString()
                guard keys.insert(key).inserted else { return true }
                skipWhitespace()
                try consume(UInt8(ascii: ":"))
                if try scanValue() { return true }
                skipWhitespace()
                if consumeIfPresent(UInt8(ascii: "}")) { return false }
                try consume(UInt8(ascii: ","))
            }
        }

        private mutating func scanArray() throws -> Bool {
            try consume(UInt8(ascii: "["))
            skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "]")) { return false }

            while true {
                if try scanValue() { return true }
                skipWhitespace()
                if consumeIfPresent(UInt8(ascii: "]")) { return false }
                try consume(UInt8(ascii: ","))
            }
        }

        private mutating func scanString() throws -> String {
            let start = index
            try consume(UInt8(ascii: "\""))
            var escaped = false
            while let byte = currentByte {
                index += 1
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    let token = Data(bytes[start ..< index])
                    guard let decoded = try JSONSerialization.jsonObject(
                        with: token,
                        options: [.fragmentsAllowed]
                    ) as? String else {
                        throw ScanError.malformedDocument
                    }
                    return decoded
                }
            }
            throw ScanError.malformedDocument
        }

        private mutating func scanPrimitive() throws {
            let start = index
            while let byte = currentByte,
                  !Self.isWhitespace(byte),
                  byte != UInt8(ascii: ","),
                  byte != UInt8(ascii: "]"),
                  byte != UInt8(ascii: "}")
            {
                index += 1
            }
            guard index > start else { throw ScanError.malformedDocument }
        }

        private mutating func skipWhitespace() {
            while let byte = currentByte, Self.isWhitespace(byte) {
                index += 1
            }
        }

        private mutating func consume(_ expected: UInt8) throws {
            guard consumeIfPresent(expected) else { throw ScanError.malformedDocument }
        }

        private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
            guard currentByte == expected else { return false }
            index += 1
            return true
        }

        private var currentByte: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
    }
}
