/// The single source of truth for what makes a character or token "technical
/// structure" rather than a natural-language word.
///
/// Both the input-session reducer (which decides whether a tracked token is
/// technical) and the language detector (which refuses to convert technical
/// tokens) must agree on this definition. Keeping one predicate here prevents
/// inconsistent decisions at the boundaries, e.g. `user_name`, `a/b`, `x=1`.
public enum TechnicalToken {
    /// Non-alphabetic symbols that signal machine-oriented structure —
    /// identifiers, paths, query strings and key=value pairs — never a word
    /// that should be language-corrected.
    public static let structuralCharacters: Set<Character> = ["_", "@", "/", "\\", "=", "?", "&"]

    /// A single character is technical when it is a digit or a structural symbol.
    public static func isTechnical(_ character: Character) -> Bool {
        character.isNumber || structuralCharacters.contains(character)
    }

    /// A string is technical when it contains at least one technical character.
    public static func containsTechnical(_ text: String) -> Bool {
        text.contains(where: isTechnical)
    }
}
