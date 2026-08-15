import ApplicationServices
import CoreFoundation

/// Fail-closed casts from an opaque Core Foundation value to a concrete
/// Accessibility type.
///
/// The Accessibility API returns attribute values as `CFTypeRef`. A force cast
/// (`value as! AXUIElement`) crashes the process when the API hands back a
/// malformed or unexpected type. Under the fail-closed contract (see ADR-0003)
/// any anomaly in the observed AX data must be treated as *absence of proof*,
/// never as permission to inject text. A crash is the worst possible outcome: it
/// is neither safe nor recoverable.
///
/// These helpers verify the runtime Core Foundation type id first and only then
/// bridge to the concrete type, so a bad value degrades to "no evidence"
/// (`nil`) instead of trapping. No force casts (`as!`) are used: after the type
/// id matches, `unsafeDowncast` is provably safe (the Swift compiler treats a
/// conditional `as?` to a CF type as an error because it "always succeeds").
public enum AXValueCasting {
    /// Casts an opaque CF value to `AXUIElement` only when its runtime type
    /// actually is an accessibility element. Returns `nil` otherwise.
    public static func uiElement(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Casts an opaque CF value to `AXValue` only when its runtime type actually
    /// is an accessibility value (e.g. a wrapped `CFRange`). Returns `nil`
    /// otherwise.
    public static func axValue(from value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }
}
