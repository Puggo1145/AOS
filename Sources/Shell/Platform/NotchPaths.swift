import Foundation
import Dispatch

// MARK: - NotchPaths
//
// Centralizes the on-disk locations the Shell needs. Per the user's overview
// note, the Notch Agent data dir lives at `~/.notch-agent/`.

enum NotchPaths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var dataDir: URL {
        home.appendingPathComponent(".notch-agent", isDirectory: true)
    }

    static var runDir: URL {
        dataDir.appendingPathComponent("run", isDirectory: true)
    }

    static var tmpDir: URL {
        dataDir.appendingPathComponent("tmp", isDirectory: true)
    }

    static var pidFile: URL {
        runDir.appendingPathComponent("notch.pid")
    }

    // MARK: - Self-delete source retention
    //
    // `DispatchSource` is reference-counted and cancels when its last strong
    // reference is dropped. main.swift creates the source as a local then
    // hands it here so it lives for the process lifetime.
    nonisolated(unsafe) private static var selfDeleteSource: DispatchSourceFileSystemObject?

    static func retainSelfDeleteSource(_ source: DispatchSourceFileSystemObject) {
        selfDeleteSource = source
    }
}
