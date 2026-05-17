import Foundation
import Dispatch

// MARK: - AOSPaths
//
// Centralizes the on-disk locations the Shell needs. Per the user's overview
// note, the AOS data dir lives at `~/.aos/`.

enum AOSPaths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var aosDir: URL {
        home.appendingPathComponent(".aos", isDirectory: true)
    }

    static var runDir: URL {
        aosDir.appendingPathComponent("run", isDirectory: true)
    }

    static var tmpDir: URL {
        aosDir.appendingPathComponent("tmp", isDirectory: true)
    }

    static var pidFile: URL {
        runDir.appendingPathComponent("aos.pid")
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
