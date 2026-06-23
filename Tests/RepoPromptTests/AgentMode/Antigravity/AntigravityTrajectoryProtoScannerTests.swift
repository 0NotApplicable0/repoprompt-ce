@testable import RepoPrompt
import XCTest

final class AntigravityTrajectoryProtoScannerTests: XCTestCase {
    static func varint(_ v: UInt64) -> [UInt8] {
        var value = v, out: [UInt8] = []
        repeat {
            var b = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { b |= 0x80 }
            out.append(b)
        } while value != 0
        return out
    }

    static func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    func testParsesStringAndNestedFields() {
        // field 1 = "id", field 5 = nested { field 2 = 200 bytes }
        let nested = Self.field(2, Array(repeating: 0x78, count: 200)) // forces a 2-byte length varint
        let bytes = Self.field(1, Array("id".utf8)) + Self.field(5, nested)
        let top = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(Data(bytes))
        XCTAssertEqual(top[1].flatMap { String(data: $0, encoding: .utf8) }, "id")
        let inner = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(top[5] ?? Data())
        XCTAssertEqual(inner[2]?.count, 200)
    }

    func testSkipsVarintFieldsAndStopsOnTruncation() {
        // field 1 = varint 8 (wire 0), then a truncated field 5 header.
        let bytes: [UInt8] = [0x08, 0x08, 0x2A, 0x32] // 0x2a=field5 wire2, len 50, no payload
        let f = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(Data(bytes))
        XCTAssertNil(f[1])
        XCTAssertNil(f[5]) // varint skipped, truncated field dropped, no crash
    }

    func testEmptyInputYieldsNoFields() {
        XCTAssertTrue(AntigravityTrajectoryProtoScanner.lengthDelimitedFields(Data()).isEmpty)
    }
}
