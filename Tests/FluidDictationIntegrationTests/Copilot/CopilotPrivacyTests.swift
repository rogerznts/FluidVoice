@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers T049 and `FR-028`: meeting content must never reach logs, analytics,
/// or diagnostics.
///
/// This suite exists because the rule was broken in practice, not in theory.
/// Diagnostic logging added while chasing a bug wrote 229 lines of real meeting
/// speech to `~/Library/Logs/Fluid/Fluid.log` before anyone noticed. Reviewing
/// diffs did not catch it; a test that reads the source does.
final class CopilotPrivacyTests: XCTestCase {
    /// Source files that handle meeting content and therefore could leak it.
    private static let auditedFiles = [
        "LiveTranscriptionTap.swift",
        "MeetingCopilotService.swift",
        "CopilotInsightEngine.swift",
        "CopilotNoteExtractor.swift",
        "CopilotWebSearchService.swift",
        "MeetingSessionCoordinator+Copilot.swift",
    ]

    /// Interpolations that would put speech, suggestions, or questions into a
    /// log line. Counts and lengths are fine; the words are not.
    private static let forbiddenInterpolations = [
        "\\(text)",
        "\\(quoted)",
        "\\(body)",
        "\\(response)",
        "\\(question)",
        "\\(accumulated)",
        "\\(segment.text)",
        "\\(insight.body)",
        "\\(message.content)",
        ".prefix(",
    ]

    private func copilotSourceDirectory() throws -> URL {
        // Walk up from this test file to the repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { url.deleteLastPathComponent() }
        let directory = url
            .appendingPathComponent("Sources/Fluid/Services/Meeting/Copilot", isDirectory: true)

        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Copilot sources not reachable from the test bundle at \(directory.path)")
        }
        return directory
    }

    func testNoMeetingContentIsInterpolatedIntoLogLines() throws {
        let directory = try self.copilotSourceDirectory()

        for fileName in Self.auditedFiles {
            let url = directory.appendingPathComponent(fileName)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("Could not read \(fileName) — the audit list is stale")
                continue
            }

            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                guard text.contains("DebugLogger") || Self.isInsideLogCall(text) else { continue }

                for pattern in Self.forbiddenInterpolations where text.contains(pattern) {
                    XCTFail(
                        """
                        \(fileName):\(index + 1) logs meeting content via \(pattern).
                        Log lengths and counts, never the words (FR-028).
                        """
                    )
                }
            }
        }
    }

    /// A log call spans several lines; the string literal sits on its own.
    /// Matching quoted lines with interpolation catches those continuations.
    private static func isInsideLogCall(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("\"") && trimmed.contains("\\(")
    }

    // MARK: - Exports

    /// `FR-024`: exports carry the briefing, not internal machinery.
    func testBriefingCarriesNoModelMetadata() {
        let briefing = CopilotBriefing(
            profileID: "seed.sales.en",
            profileName: "Sales",
            body: "## Summary\nStrong call.",
            basis: .finalTranscript
        )

        let mirror = Mirror(reflecting: briefing)
        let fieldNames = mirror.children.compactMap(\.label)

        for forbidden in ["embedding", "fingerprint", "confidence", "logits", "model"] {
            XCTAssertFalse(
                fieldNames.contains { $0.lowercased().contains(forbidden) },
                "briefings must not carry \(forbidden) into exports"
            )
        }
    }

    /// `FR-025`: nothing leaves the Mac unless the user chose a cloud provider.
    func testLocalIsTheDefaultProviderChoice() {
        let artifacts = CopilotSessionArtifacts(sessionID: UUID())

        XCTAssertEqual(artifacts.providerChoice, .local)
        XCTAssertFalse(CopilotProviderChoice.local.leavesDevice)
        XCTAssertTrue(CopilotProviderChoice.cloud.leavesDevice)
    }

    /// `DEC-COP-003`: grounded search is the one path that reaches the open
    /// internet, and it must refuse rather than pretend when unsupported.
    func testWebSearchRefusesUnsupportedProviders() {
        let openAI = CopilotProviderRoute(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o",
            apiKey: "key",
            choice: .cloud
        )
        let gemini = CopilotProviderRoute(
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            model: "models/gemini-2.5-flash",
            apiKey: "key",
            choice: .cloud
        )

        XCTAssertFalse(CopilotWebSearchService.isSupported(route: openAI))
        XCTAssertNil(CopilotWebSearchService.make(route: openAI))
        XCTAssertTrue(CopilotWebSearchService.isSupported(route: gemini))
        XCTAssertEqual(CopilotWebSearchService.make(route: gemini)?.model, "gemini-2.5-flash")
    }

    func testWebSearchRefusesRoutesWithoutCredentials() {
        let noKey = CopilotProviderRoute(
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            model: "models/gemini-2.5-flash",
            apiKey: "",
            choice: .cloud
        )

        XCTAssertFalse(CopilotWebSearchService.isSupported(route: noKey))
    }
}
