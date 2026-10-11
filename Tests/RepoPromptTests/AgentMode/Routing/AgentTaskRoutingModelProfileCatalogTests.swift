@testable import RepoPromptApp
import XCTest

final class AgentTaskRoutingModelProfileCatalogTests: XCTestCase {
    private static let preamble = "Evidence snapshot 2026-10-10 (provider-published; API list price is a comparison proxy and CLI or subscription billing may differ): "
    private static let profiles = [
        "gemini-3.8-flash": "Gemini 3.8 Flash (published 2026-09-02) is Google's workhorse tier for long-horizon agentic workflows; Google reports 73.7% on DeepSWE v1.1, with a 1,048,576-token context window and 65,536-token maximum output. API list price: $0.75 input / $3.75 output per 1M tokens through December 31, 2026 ($1.50/$7.50 starting January 1, 2027), cached input $0.075 through December 31, 2026 ($0.15 from 2027-01-01).",
        "gemini-3.1-pro": "Gemini 3.1 Pro (published 2026-02-19) is Google's flagship multimodal reasoning tier for complex coding tasks; Google reports 80.6% on SWE-Bench Verified (single attempt, Thinking (High)), with a 1,048,576-token context window and 65,536-token maximum output. API list price: $2.00 input / $12.00 output per 1M tokens (prompts <= 200k; $4.00 / $18.00 above), cached input $0.20 for prompts <= 200k ($0.40 above).",
        "grok-4.7": "Grok 4.7 (released 2026-09-21) is xAI's flagship model for agentic coding and knowledge work, featuring 46.3% on CursorBench 4.0 at xHigh effort and a 500,000-token context window. API list price: $2.00 input / $0.50 cached / $6.00 output per 1M tokens for prompts < 200k; $4.00 / $1.00 / $12.00 at >= 200k.",
        "composer-2.5": "Composer 2.5 (released 2026-05-18) is Cursor's proprietary agentic coding model optimized for edit-test-edit loops; Cursor reports 69.3% on Terminal-Bench 2.0 and 79.8% on SWE-Bench Multilingual (image, changelog benchmark table), with a 200K-token context window. API list price: Standard $0.50 input / $2.50 output per 1M tokens, Fast $3.00 / $15.00; cache read $0.2 Standard / $0.5 Fast."
    ]

    private func target(_ agent: String, _ model: String) -> AgentRoutingExecutableTarget {
        AgentRoutingExecutableTarget(agentRaw: agent, modelRaw: model, reasoningEffortRaw: nil, modelParameters: [])
    }

    func testNewFamiliesHaveAuditedProfiles() throws {
        let fixtures = [
            ("antigravity", "gemini-3.8-flash-high", "gemini-3.8-flash"),
            ("antigravity", "gemini-3.1-pro-high", "gemini-3.1-pro"),
            ("grok", "grok-4.7", "grok-4.7"),
            ("cursor", "grok-4.7", "grok-4.7"),
            ("cursor", "composer-2.5", "composer-2.5")
        ]
        for (agent, model, family) in fixtures {
            let expected = try XCTUnwrap(Self.profiles[family])
            let actual = AgentTaskRoutingModelProfileCatalog.modelDescription(for: target(agent, model))
            XCTAssertEqual(actual, Self.preamble + expected, "\(agent):\(model)")
            XCTAssertTrue(actual.contains("API list price:"), "\(agent):\(model)")
            XCTAssertFalse(actual.contains("No audited benchmark"), "\(agent):\(model)")
        }
    }

    func testAntigravityIdentityDropsEffortSuffix() throws {
        let fixtures = [
            ("gemini-3.8-flash-high", "gemini-3.8-flash"),
            ("gemini-3.8-flash-medium", "gemini-3.8-flash"),
            ("gemini-3.8-flash-low", "gemini-3.8-flash"),
            ("gemini-3.1-pro-high", "gemini-3.1-pro"),
            ("gemini-3.1-pro-low", "gemini-3.1-pro")
        ]
        for (model, family) in fixtures {
            let expected = try XCTUnwrap(Self.profiles[family])
            let actual = AgentTaskRoutingModelProfileCatalog.modelDescription(for: target("antigravity", model))
            XCTAssertEqual(actual, Self.preamble + expected, model)
            XCTAssertFalse(actual.contains("No audited benchmark"), model)
        }
    }

    func testUnknownIdentityKeepsUncertainProfile() {
        let fixtures = [
            ("antigravity", "gemini-3.7-flash-high"),
            ("antigravity", "claude-opus-5-5-high"),
            ("cursor", "gemini-3.8-flash-high"),
            ("grok", "gemini-3.1-pro-high")
        ]
        for (agent, model) in fixtures {
            let actual = AgentTaskRoutingModelProfileCatalog.modelDescription(for: target(agent, model))
            XCTAssertTrue(actual.contains("No audited benchmark or pricing profile"), "\(agent):\(model)")
            XCTAssertTrue(actual.contains("Treat capability and cost as uncertain"), "\(agent):\(model)")
        }
    }

    func testEvidenceVersionAdvanced() {
        XCTAssertEqual(AgentTaskRoutingModelProfileCatalog.evidenceVersion, "rpce.model-routing-evidence.2026-10-10.1")
        XCTAssertEqual(AgentTaskRoutingModelProfileCatalog.rubricVersion, "rpce.automatic-utility-frontier.v2-evidence-2026-10-10.1")
    }
}
