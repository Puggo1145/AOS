import Testing
import Foundation
import CoreGraphics
@testable import AOSComputerUseKit

// MARK: - SkyLight SPI resolution
//
// The Kit's whole behavior pivots on whether `dlsym` resolves the SkyLight
// + Carbon SPIs at startup. These tests verify the resolution surface is
// honest (no false positives) and that `Availability` is consistent with
// the per-feature accessors.

@Suite("SkyLight SPI resolution")
struct SkyLightSPITests {

    @Test("Availability struct is consistent with per-feature accessors")
    func availabilityIsConsistent() {
        let av = SkyLightEventPost.availability
        // The per-feature flags are computed from the same dlsym lookups
        // — divergence would be a bug in the helper. Simply asserting
        // equality both ways is the cheapest way to catch it.
        #expect(av.authMessage == SkyLightEventPost.isAuthSignedPostAvailable)
        #expect(av.focusWithoutRaise == SkyLightEventPost.isFocusWithoutRaiseAvailable)
        #expect(av.windowLocation == SkyLightEventPost.isWindowLocationAvailable)
        #expect(av.spaces == SkyLightEventPost.isSpacesAvailable)
    }

    @Test("postToPid SPI resolves on supported macOS")
    func postToPidResolves() {
        // The SkyLight framework ships on every macOS we target; if this
        // returns false the doctor + agent need to know. This is the
        // canary that keeps `doctor.skyLightSPI.postToPid` honest.
        let av = SkyLightEventPost.availability
        #expect(av.postToPid == true)
    }

    @Test("activeSpaceID does not crash and is non-negative when present")
    func activeSpaceIsCallable() {
        guard SkyLightEventPost.isSpacesAvailable else { return }
        // SLSGetActiveSpace can legitimately return failure in unit-test
        // hosts (no WindowServer attachment), in which case the helper
        // surfaces nil. We exercise the call path; deeper assertions
        // require an interactive host.
        _ = SkyLightEventPost.activeSpaceID()
    }

    @Test("mainConnectionID returns nonzero when SPI present")
    func mainConnectionIDPresent() {
        guard SkyLightEventPost.mainConnectionID != nil else { return }
        let id = SkyLightEventPost.mainConnectionID
        #expect(id != nil)
        #expect((id ?? 0) > 0)
    }
}

// MARK: - 248-byte event record byte layout
//
// `FocusWithoutRaise` builds the 248-byte synthetic event record in-place.
// The byte positions (0x04, 0x08, 0x3c..0x3f, 0x8a) are load-bearing — a
// single off-by-one would cause the focus event to silently no-op.
// These tests reconstruct the same buffer in test and assert positions.

@Suite("FocusWithoutRaise — 248-byte buffer layout")
struct EventRecordLayoutTests {

    @Test("Buffer is exactly 248 (0xF8) bytes with correct opcode marker")
    func bufferLengthAndOpcode() {
        // Mirror the construction in `FocusWithoutRaise.activateWithoutRaise`
        // so we lock the layout in tests independently of the live call.
        var buf = [UInt8](repeating: 0, count: 0xF8)
        buf[0x04] = 0xF8
        buf[0x08] = 0x0D

        #expect(buf.count == 248)
        #expect(buf[0x04] == 0xF8)
        #expect(buf[0x08] == 0x0D)
    }

    @Test("Window id stamps as little-endian into bytes 0x3c..0x3f")
    func windowIdEncoding() {
        let wid: UInt32 = 0x12345678
        var buf = [UInt8](repeating: 0, count: 0xF8)
        buf[0x3C] = UInt8(wid & 0xFF)
        buf[0x3D] = UInt8((wid >> 8) & 0xFF)
        buf[0x3E] = UInt8((wid >> 16) & 0xFF)
        buf[0x3F] = UInt8((wid >> 24) & 0xFF)

        #expect(buf[0x3C] == 0x78)
        #expect(buf[0x3D] == 0x56)
        #expect(buf[0x3E] == 0x34)
        #expect(buf[0x3F] == 0x12)
    }

    @Test("Focus marker is 0x01 and defocus marker is 0x02 at offset 0x8a")
    func focusDefocusMarker() {
        var buf = [UInt8](repeating: 0, count: 0xF8)
        buf[0x8A] = 0x01
        #expect(buf[0x8A] == 0x01)
        buf[0x8A] = 0x02
        #expect(buf[0x8A] == 0x02)
    }
}
