import Testing
import Foundation

@Suite("Run script")
struct RunScriptTests {

    @Test("run.sh terminates an existing Notch Agent process before opening the rebuilt app")
    func runScriptRelaunchesNotchAgent() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("Scripts/run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let commandLines = script
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")

        let terminateRange = try #require(commandLines.range(of: #"pkill -x "Notch Agent""#))
        let openRange = try #require(commandLines.range(of: #"open "Notch Agent.app""#))
        #expect(terminateRange.lowerBound < openRange.lowerBound)
    }

    @Test("build-app.sh supports explicit ad-hoc signing for friend test builds")
    func buildAppSupportsAdHocSigning() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("Scripts/build-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains(#"APP_BUNDLE="${NOTCH_APP_BUNDLE_PATH:-Notch Agent.app}""#))
        #expect(script.contains(#"CODESIGN_IDENTITY="${NOTCH_CODESIGN_IDENTITY:--}""#))
        #expect(script.contains(#"if [ "$CODESIGN_IDENTITY" = "-" ]"#))
        #expect(script.contains(#"Signing ad-hoc for local friend testing"#))
        #expect(script.contains(#"grep -Fq -- "$CODESIGN_IDENTITY""#))
    }

    @Test("build-dmg.sh creates a Finder drag install window")
    func buildDmgCreatesFinderInstallWindow() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("Scripts/build-dmg.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains(#"APP_BUNDLE="$TMP_ROOT/Notch Agent.app""#))
        #expect(script.contains(#"NOTCH_APP_BUNDLE_PATH="$APP_BUNDLE""#))
        #expect(script.contains("NSColor.white.setFill()"))
        #expect(script.contains("set background picture of viewOptions"))
        #expect(script.contains("set sidebar width of container window to 0"))
        #expect(script.contains(#"set position of item "Notch Agent.app" of container window"#))
        #expect(script.contains(#"set position of item "Applications" of container window"#))
        #expect(script.contains("Drag the app into Applications"))
        #expect(!script.contains("First launch:"))
        #expect(!script.contains(#"let leftLabel = "Notch Agent""#))
        #expect(!script.contains(#"let rightLabel = "Applications""#))
        #expect(!script.contains("bless --folder"))
    }
}
