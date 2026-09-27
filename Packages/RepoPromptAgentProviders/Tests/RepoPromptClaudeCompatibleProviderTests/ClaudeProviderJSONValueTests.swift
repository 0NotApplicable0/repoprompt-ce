import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeProviderJSONValueTests: XCTestCase {
    func testFoundationJSONNumbersRemainNumbers() throws {
        let data = Data(#"{"a":0,"b":1,"c":2,"d":1.5,"e":true,"f":false,"g":1.0,"h":[0,1],"i":{"j":1},"k":9007199254740993,"l":-1}"#.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let values = try object.mapValues { try ClaudeProviderJSONValue(any: $0) }

        XCTAssertEqual(values["a"], .integer(0))
        XCTAssertEqual(values["b"], .integer(1))
        XCTAssertEqual(values["c"], .integer(2))
        XCTAssertEqual(values["d"], .double(1.5))
        XCTAssertEqual(values["e"], .bool(true))
        XCTAssertEqual(values["f"], .bool(false))
        XCTAssertEqual(values["g"], .integer(1))
        XCTAssertEqual(values["h"], .array([.integer(0), .integer(1)]))
        XCTAssertEqual(values["i"], .object(["j": .integer(1)]))
        XCTAssertEqual(values["k"], .integer(9_007_199_254_740_993))
        XCTAssertEqual(values["l"], .integer(-1))
    }

    func testNativeValuesRetainTheirJSONKinds() throws {
        XCTAssertEqual(try ClaudeProviderJSONValue(any: true), .bool(true))
        XCTAssertEqual(try ClaudeProviderJSONValue(any: 1), .integer(1))
        XCTAssertEqual(try ClaudeProviderJSONValue(any: 1.5), .double(1.5))
    }
}
