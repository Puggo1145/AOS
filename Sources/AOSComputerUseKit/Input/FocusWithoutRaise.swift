import CoreGraphics
import Foundation

// MARK: - FocusWithoutRaise
//
// Yabai-style "make AppKit believe `pid` is active without asking
// WindowServer to reorder windows or trigger Space follow". Per
// `docs/designs/computer-use.md` §"事件投递路径" the recipe is:
//
//   1. `_SLPSGetFrontProcess(&prevPSN)` — capture current frontmost.
//   2. `GetProcessForPID(targetPid, &targetPSN)`.
//   3. `SLPSPostEventRecordTo(prevPSN, ...)` with `bytes[0x8a] = 0x02`
//      (defocus marker) — tells WindowServer the prior front lost focus.
//   4. `SLPSPostEventRecordTo(targetPSN, ...)` with `bytes[0x8a] = 0x01`
//      (focus marker) and the target window id stamped into bytes
//      `0x3c..0x3f` little-endian.
//
// The 248-byte buffer layout, per yabai's source verified on macOS 15/26:
//
//   bytes[0x04] = 0xf8     (opcode high)
//   bytes[0x08] = 0x0d     (opcode low)
//   bytes[0x3c..0x3f]      (LE-encoded CGWindowID)
//   bytes[0x8a]            (0x01 = focus, 0x02 = defocus)
//   all other bytes        zero
//
// **Deliberately omits** yabai's follow-up `SLPSSetFrontProcessWithOptions`
// step. Empirically:
//
//   - flag `0x100` (kCPSUserGenerated) → window visibly raises + Space follow
//   - flag `0x400` (kCPSNoWindows)     → no raise / no follow, but Chrome's
//                                        user-activation gate stops treating
//                                        the target as live input
//   - skip entirely → no raise, no follow, AND Chrome still accepts the
//                      following synthetic clicks as trusted user gestures
//                      (the `0x01` focus event is what its gate latches onto)

public enum FocusWithoutRaise {
    /// Activate `targetPid` for `targetWid` without raising the window or
    /// triggering Space follow. Returns `false` when the SkyLight SPIs
    /// aren't available or any of the event posts failed — caller falls
    /// back to either `NSRunningApplication.activate` (visible) or
    /// foregoing the activation step.
    @discardableResult
    public static func activateWithoutRaise(
        targetPid: pid_t, targetWid: CGWindowID
    ) -> Bool {
        guard SkyLightEventPost.isFocusWithoutRaiseAvailable else { return false }

        // PSN buffers: 8 bytes each (high UInt32, low UInt32).
        var prevPSN = [UInt32](repeating: 0, count: 2)
        var targetPSN = [UInt32](repeating: 0, count: 2)

        let prevOk = prevPSN.withUnsafeMutableBytes { raw in
            SkyLightEventPost.getFrontProcess(raw.baseAddress!)
        }
        guard prevOk else { return false }

        let targetOk = targetPSN.withUnsafeMutableBytes { raw in
            SkyLightEventPost.getProcessPSN(forPid: targetPid, into: raw.baseAddress!)
        }
        guard targetOk else { return false }

        var buf = [UInt8](repeating: 0, count: 0xF8)
        buf[0x04] = 0xF8
        buf[0x08] = 0x0D
        let wid = UInt32(targetWid)
        buf[0x3C] = UInt8(wid & 0xFF)
        buf[0x3D] = UInt8((wid >> 8) & 0xFF)
        buf[0x3E] = UInt8((wid >> 16) & 0xFF)
        buf[0x3F] = UInt8((wid >> 24) & 0xFF)

        // Defocus previous front.
        buf[0x8A] = 0x02
        let defocusOk = prevPSN.withUnsafeBytes { psnRaw in
            buf.withUnsafeBufferPointer { bp in
                SkyLightEventPost.postEventRecordTo(
                    psn: psnRaw.baseAddress!, bytes: bp.baseAddress!)
            }
        }

        // Focus target.
        buf[0x8A] = 0x01
        let focusOk = targetPSN.withUnsafeBytes { psnRaw in
            buf.withUnsafeBufferPointer { bp in
                SkyLightEventPost.postEventRecordTo(
                    psn: psnRaw.baseAddress!, bytes: bp.baseAddress!)
            }
        }

        return defocusOk && focusOk
    }
}
