import Foundation

/// Why an ingest key was refused before a single request was made.
///
/// Checked client-side because the alternative is a silent no-op: the gateway answers a
/// bad key with 401 on every POST, and a best-effort transport by definition swallows
/// that. Better to refuse at `start()`, where a developer is looking.
public enum IngestKeyProblem: Equatable, Sendable, CustomStringConvertible {
    case missing
    case wrongPrefix

    public var description: String {
        switch self {
        case .missing:
            return "ingestKey is not set. Set it to your public ingest key (maple_pk_…)."
        case .wrongPrefix:
            return "ingestKey must start with maple_pk_ (or maple_sk_). The gateway rejects anything else with 401."
        }
    }
}

public enum IngestKey {
    /// The gateway's drop-everything token. Authenticates, stores nothing, meters
    /// nothing — useful for pointing a build at a gateway without a real key.
    public static let sentinel = "MAPLE_TEST"

    /// Mirrors `infer_ingest_key_type` at the gateway: anything not prefixed
    /// `maple_pk_`/`maple_sk_` resolves to no key at all and comes back 401.
    public static func validate(_ ingestKey: String?) -> IngestKeyProblem? {
        guard let key = ingestKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return .missing
        }
        if key == sentinel { return nil }
        guard key.hasPrefix("maple_pk_") || key.hasPrefix("maple_sk_") else { return .wrongPrefix }
        return nil
    }
}
