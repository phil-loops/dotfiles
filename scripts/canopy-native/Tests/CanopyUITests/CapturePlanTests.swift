import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

struct CapturePlanTests {
    func config(_ shots: [String] = ["review=/v2/b/r/feature space =? !menu ~0.25 ? #"]) -> AppConfig {
        var config = AppConfig(); config.shots = shots; return config
    }

    @Test func validPlansRetainAddressesAndDistinguishLiteralKeysFromDiagnostics() throws {
        let plan = try CapturePlan(config())
        #expect(plan.shots == [.init(name: "review", address: "/v2/b/r/feature", actions: [.key("space"), .key("?"), .draw("menu"), .wait(250_000_000), .state, .terminalState])])
        #expect(plan.settle == 4_000_000_000)
        for address in ["/v2", "/v2/", "/v2/dashboard", "/v2/machine", "/v2/b/r/my/branch?commit=abc1234..def5678", "/v2/tutor/a%20session", "/v2/keytutor/stack"] {
            #expect(CapturePlan.knownAddress(address))
        }
    }

    @Test func malformedPlansCannotSilentlySkipOrOverwriteACapture() {
        for shots in [[], ["oops"], ["empty="], ["=/v2"], ["bad=/v2/typo"], ["bad=/v2/b"], ["x=/v2", "x=/v2/dashboard"], ["x=/v2", "X=/v2/dashboard"], ["é=/v2", "e=/v2/dashboard"], ["x=/v2 !x"], ["x=/v2 !"], ["x=/v2 ="], ["x=/v2 >write\\r"], ["x=/v2 ~oops"]] {
            #expect(throws: (any Error).self) { _ = try CapturePlan(config(shots)) }
        }
    }

    @Test func malformedScopeQueriesCannotCaptureAnotherDiff() {
        for query in ["base=typo", "base=", "base", "commit=", "commit=abc/def", "commit=...", "commit=a...b", "commit=a..", "commit=a..b..c", "base=main&commit=abc1234", "base=main&base=outgoing", "commit=a&commit=b"] {
            #expect(!CapturePlan.knownAddress("/v2/b/r/feature?\(query)"))
        }
        #expect(CapturePlan.knownAddress("/v2/b/r/feature?base=main"))
        #expect(CapturePlan.knownAddress("/v2/b/r/feature?commit=abc1234"))
        #expect(!CapturePlan.knownAddress("/v2/dashboard?base=main"))
    }

    @Test func malformedCLIValuesRemainErrorsUntilPreflight() {
        for args in [["--dump-wait", "oops"], ["--dump-wait"], ["--size", "oops"], ["--size", "1xx2"], ["--size"], ["--shot"], ["--shoot"]] {
            let parsed = AppConfig.parse(args)
            #expect(!parsed.captureErrors.isEmpty)
            #expect(throws: (any Error).self) { _ = try CapturePlan(parsed) }
        }
        #expect(AppConfig.parse(["--shoot", "/tmp/shots"]).shootRequested)
        #expect(!AppConfig.parse([]).shootRequested)
    }

    @Test func conflictingModesCannotBypassCaptureIsolation() {
        for args in [["--shoot", "/tmp/x", "--bench"], ["--shoot", "/tmp/x", "--dump"], ["--shoot-fixture", "/tmp/source", "--dump"], ["--shot", "x=/v2"], ["--shoot-fixture", "/tmp/source"], ["--bench", "--dump"], ["--dump", "--shot"], ["--dump", "--shoot-fixture"], ["--bench", "--size", "nonsense"]] {
            #expect(AppConfig.parse(args).launchError != nil)
        }
        #expect(AppConfig.parse(["--shoot", "/tmp/x", "--shoot-fixture", "/tmp/source", "--shot", "x=/v2"]).launchError == nil)
        #expect(AppConfig.parse(["--bench"]).launchError == nil)
        #expect(AppConfig.parse(["--dump"]).launchError == nil)
    }

    @Test func namesStayWithinTheArtifactDirectory() {
        for name in ["", ".", "..", "../outside", "a/b", "a\\b", "line\nbreak", "nul\0byte", String(repeating: "x", count: 201)] {
            #expect(throws: (any Error).self) { try CapturePlan.validateName(name) }
        }
        #expect(throws: Never.self) { try CapturePlan.validateName("review narrow-😀") }
    }

    @Test func invalidTimingsAndViewportsFailBeforeAnyAppIsCreated() {
        for delay in [Double.nan, .infinity, -.infinity, -1, 61] {
            var config = config(); config.dumpWait = delay
            #expect(throws: (any Error).self) { _ = try CapturePlan(config) }
            #expect(throws: (any Error).self) { _ = try CapturePlan(self.config(["x=/v2 ~\(delay)"])) }
        }
        for size in [Double.nan, .infinity, 0, -1, 8193] {
            var config = config(); config.shootWidth = size
            #expect(throws: (any Error).self) { _ = try CapturePlan(config) }
        }
        var huge = config(); huge.shootWidth = 8192; huge.shootHeight = 8192
        #expect(throws: (any Error).self) { _ = try CapturePlan(huge) }
    }

    @Test func outputCreatesItsDirectoryAndReportsOnlyCompletedWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-capture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { _ = try CaptureOutput("") }
        let output = try CaptureOutput(root.appendingPathComponent("nested").path)
        let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let url = try output.writePNG(bytes, named: "first")
        #expect(try Data(contentsOf: url) == bytes)
        #expect(throws: (any Error).self) { _ = try output.writePNG(nil, named: "first") }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(throws: (any Error).self) { _ = try output.writePNG(Data(), named: "empty") }
        #expect(throws: (any Error).self) { _ = try output.writePNG(bytes, named: "../outside") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/blocked.png"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { _ = try output.writePNG(bytes, named: "blocked") }
        let file = root.appendingPathComponent("file"); try bytes.write(to: file)
        #expect(throws: (any Error).self) { _ = try CaptureOutput(file.path) }
    }
}
