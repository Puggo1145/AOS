import Testing
import Foundation

@Suite("Run script")
struct RunScriptTests {

    @Test("run.sh builds and relaunches the separate dev app identity")
    func runScriptRelaunchesDevNotchAgent() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("Scripts/run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let commandLines = script
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")

        #expect(commandLines.contains(#"DEV_APP_NAME="notch-agent-dev""#))
        #expect(commandLines.contains(#"DEV_BUNDLE_ID="com.notch-agent.shell.dev""#))
        #expect(commandLines.contains(#"LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister""#))
        #expect(commandLines.contains(#"NOTCH_APP_NAME="$DEV_APP_NAME""#))
        #expect(commandLines.contains(#"NOTCH_APP_EXECUTABLE="$DEV_APP_NAME""#))
        #expect(commandLines.contains(#"NOTCH_BUNDLE_ID="$DEV_BUNDLE_ID""#))
        let terminateRange = try #require(commandLines.range(of: #"pkill -x "$DEV_APP_NAME""#))
        let registerRange = try #require(commandLines.range(of: #""$LSREGISTER" -f "$DEV_BUNDLE_PATH""#))
        let openRange = try #require(commandLines.range(of: #"open "$DEV_BUNDLE_PATH""#))
        #expect(terminateRange.lowerBound < registerRange.lowerBound)
        #expect(registerRange.lowerBound < openRange.lowerBound)
        #expect(terminateRange.lowerBound < openRange.lowerBound)
    }

    @Test("build-app.sh supports explicit ad-hoc signing for friend test builds")
    func buildAppSupportsAdHocSigning() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("Scripts/build-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains(#"APP_BUNDLE="${NOTCH_APP_BUNDLE_PATH:-Notch Agent.app}""#))
        #expect(script.contains(#"APP_NAME="${NOTCH_APP_NAME:-Notch Agent}""#))
        #expect(script.contains(#"APP_EXECUTABLE="${NOTCH_APP_EXECUTABLE:-$APP_NAME}""#))
        #expect(script.contains(#"APP_BUNDLE_ID="${NOTCH_BUNDLE_ID:-com.notch-agent.shell}""#))
        #expect(script.contains(#"plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_ID""#))
        #expect(script.contains(#"--identifier "$APP_BUNDLE_ID""#))
        #expect(script.contains(#"CODESIGN_IDENTITY="${NOTCH_CODESIGN_IDENTITY:--}""#))
        #expect(script.contains(#"APP_REQUIREMENTS_ARGS=()"#))
        #expect(script.contains(#"if [ "$CODESIGN_IDENTITY" = "-" ]"#))
        #expect(script.contains(#"Signing ad-hoc for local friend testing"#))
        #expect(script.contains(#"APP_REQUIREMENTS_ARGS=(--requirements "=designated => identifier \"$APP_BUNDLE_ID\"")"#))
        #expect(script.contains(#"grep -Fq -- "$CODESIGN_IDENTITY""#))
    }

    @Test("sidecar frozen install uses a committable bun lockfile")
    func sidecarFrozenInstallUsesCommittableBunLockfile() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(contentsOf: root.appendingPathComponent("Scripts/build-app.sh"), encoding: .utf8)
        let gitignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        let ignoredNames = Set(gitignore
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })

        #expect(script.contains(#"cp sidecar/bun.lock "$APP_BUNDLE/Contents/Resources/sidecar/bun.lock""#))
        #expect(script.contains(#""$HOST_BUN" install --frozen-lockfile --production"#))
        #expect(!ignoredNames.contains("bun.lock"))
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

    @Test("reset-user-data.sh clears every onboarding TCC service")
    func resetUserDataClearsEveryOnboardingTCCService() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("Scripts/reset-user-data.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let loopStart = try #require(script.range(of: "for service in \\"))
        let loopTail = script[loopStart.upperBound...]
        let serviceListEnd = try #require(loopTail.range(of: "; do"))
        let serviceList = loopTail[..<serviceListEnd.lowerBound]
        let services = serviceList
            .split(separator: "\n")
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let withoutContinuation = trimmed.hasSuffix("\\") ? String(trimmed.dropLast()) : trimmed
                return withoutContinuation.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        #expect(services == [
            "ScreenCapture",
            "Accessibility",
            "SystemPolicyDesktopFolder",
            "SystemPolicyDocumentsFolder",
            "SystemPolicyDownloadsFolder",
            "AppleEvents",
        ])
    }

    @Test("reset-user-data.sh can target dev or release identities")
    func resetUserDataTargetsDevOrReleaseIdentities() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("Scripts/reset-user-data.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains(#"TARGET="${1:-dev}""#))
        #expect(script.contains(#"dev)"#))
        #expect(script.contains(#"APP_LABEL="notch-agent-dev""#))
        #expect(script.contains(#"BUNDLE_ID="com.notch-agent.shell.dev""#))
        #expect(script.contains(#"release)"#))
        #expect(script.contains(#"APP_LABEL="Notch Agent""#))
        #expect(script.contains(#"BUNDLE_ID="com.notch-agent.shell""#))
        #expect(script.contains(#"Usage: $0 [dev|release]"#))
        #expect(script.contains(#"exit 64"#))
        #expect(script.contains(#"pkill -x "${APP_LABEL}""#))
        #expect(script.contains(#"defaults delete "${BUNDLE_ID}""#))
        #expect(script.contains(#"reset_tcc_service "${service}" "${BUNDLE_ID}""#))
    }

    @Test("reset-model-config.sh can target dev or release identities")
    func resetModelConfigTargetsDevOrReleaseIdentities() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptURL = root.appendingPathComponent("Scripts/reset-model-config.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains(#"TARGET="${1:-dev}""#))
        #expect(script.contains(#"dev)"#))
        #expect(script.contains(#"APP_LABEL="notch-agent-dev""#))
        #expect(script.contains(#"BUNDLE_ID="com.notch-agent.shell.dev""#))
        #expect(script.contains(#"release)"#))
        #expect(script.contains(#"APP_LABEL="Notch Agent""#))
        #expect(script.contains(#"BUNDLE_ID="com.notch-agent.shell""#))
        #expect(script.contains(#"Usage: $0 [dev|release]"#))
        #expect(script.contains(#"exit 64"#))
        #expect(script.contains(#"pkill -x "${APP_LABEL}""#))
        #expect(script.contains("Re-run Scripts/run.sh to land directly in the dev provider picker."))
        #expect(script.contains("Re-launch Notch Agent.app to land directly in the release provider picker."))
    }
}
