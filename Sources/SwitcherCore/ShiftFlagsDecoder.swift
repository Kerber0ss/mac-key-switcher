import IOKit.hidsystem

/// Decodes the physical direction (down/up) of a specific Shift key from the
/// modifier flags of a `.flagsChanged` event.
///
/// The aggregate `.maskShift` flag is true whenever *any* Shift is held, so it
/// cannot tell whether *this* key just went down or up when both Shift keys are
/// involved (e.g. press left → press right → release left). macOS exposes the
/// per-key state in the device-dependent modifier bits (`IOLLEvent.h`):
///
/// - `NX_DEVICELSHIFTKEYMASK` (0x02) — left Shift is physically down
/// - `NX_DEVICERSHIFTKEYMASK` (0x04) — right Shift is physically down
///
/// Reading the bit for exactly the reported key code makes left and right Shift
/// independent, so two different Shift keys can never be mistaken for a repeat of
/// the same key.
public enum ShiftFlagsDecoder {
    /// Device-dependent bit that is set while the left Shift key is physically down.
    public static let leftShiftMask = UInt64(NX_DEVICELSHIFTKEYMASK)
    /// Device-dependent bit that is set while the right Shift key is physically down.
    public static let rightShiftMask = UInt64(NX_DEVICERSHIFTKEYMASK)

    /// Whether the given Shift side is physically down in the supplied flags.
    public static func isPressed(_ side: ShiftSide, flagsRawValue: UInt64) -> Bool {
        switch side {
        case .left:
            return flagsRawValue & leftShiftMask != 0
        case .right:
            return flagsRawValue & rightShiftMask != 0
        }
    }

    /// The physical direction of a `.flagsChanged` event for a Shift key.
    ///
    /// - Returns: `.keyDown` if the specific key's device bit is set, `.keyUp`
    ///   otherwise.
    public static func direction(
        for side: ShiftSide,
        flagsRawValue: UInt64
    ) -> PassiveInputEvent.Kind {
        isPressed(side, flagsRawValue: flagsRawValue) ? .keyDown : .keyUp
    }
}
