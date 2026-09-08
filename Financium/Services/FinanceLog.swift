import CloudKit
import Foundation
import os

/// Diagnostics for the calls the app makes.
///
/// The screens only ever show a sentence a person can act on — "something went
/// wrong" is the honest thing to tell somebody who cannot do anything about a
/// gRPC status code. But that sentence is also all that survived the failure,
/// which left nothing to work from when it turned out to be wrong. This keeps
/// the original, where a developer can read it and a reader never has to.
///
/// `os.Logger` rather than `print`: the lines survive into Console.app and
/// `log stream` from a device that is not attached to Xcode, which is where
/// these failures actually happen.
/// `nonisolated` because logging belongs to no actor.
///
/// The target's default isolation is the main actor, which would have put this
/// there too — and then a failure inside a network call, which happens off the
/// main actor by definition, could not report itself without hopping back. A
/// logger that can only be reached from one thread is a logger that is absent
/// exactly where things go wrong. `os.Logger` is `Sendable` and safe from
/// anywhere, so nothing is given up by saying so.
nonisolated enum FinanceLog {
    static let network = Logger(subsystem: subsystem, category: "network")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let push = Logger(subsystem: subsystem, category: "push")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.gofinancium.Financium"

    /// Whole milliseconds since an instant, for the timings in the log.
    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }

    /// Everything an error can be made to say, in one line.
    ///
    /// CloudKit failures are unwrapped to their `CKError.Code` and the retry
    /// hint when there is one — the useful half, and the part
    /// `localizedDescription` buries. A cancellation is named as such rather
    /// than reported as a fault, because it usually means the app called the
    /// request off itself.
    /// Atomic CloudKit batches also return batchRequestFailed for records that
    /// were merely rolled back. Prefer the actual failing record's error.
    static func rootCause(_ error: Error, depth: Int = 0) -> Error {
        guard depth < 8 else { return error }
        if let ck = error as? CKError, ck.code == .partialFailure,
           let nested = ck.partialErrorsByItemID, !nested.isEmpty {
            let causes = nested.values.map { rootCause($0, depth: depth + 1) }
            return primaryError(in: causes) ?? error
        }
        return error
    }

    static func primaryError(in errors: [Error]) -> Error? {
        errors.first { ($0 as? CKError)?.code != .batchRequestFailed } ?? errors.first
    }

    /// Preserve the server's explanation, not just the numeric CloudKit code.
    /// Inspect only textual error descriptions, never record payloads or share URLs.
    static func serverReason(_ error: CKError) -> String {
        let info = (error as NSError).userInfo
        let keys = [NSLocalizedFailureReasonErrorKey, NSDebugDescriptionErrorKey, NSLocalizedDescriptionKey]
        var descriptions: [String] = []
        for key in keys {
            guard let text = info[key] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !descriptions.contains(trimmed) { descriptions.append(trimmed) }
        }
        return descriptions.isEmpty ? error.localizedDescription : descriptions.joined(separator: "\n")
    }

    static func describe(_ error: Error) -> String {
        if let ck = error as? CKError {
            if ck.code == .partialFailure, let nested = ck.partialErrorsByItemID, !nested.isEmpty {
                let cause = rootCause(error)
                if (cause as? CKError)?.code != .partialFailure {
                    return "cloudkit partialFailure: " + describe(cause)
                }
            }
            var line = "cloudkit \(ck.code.rawValue) (\(ck.code)): \(serverReason(ck))"
            if let retry = ck.retryAfterSeconds {
                line += " — retry after \(retry)s"
            }
            return line
        }
        if error is CancellationError {
            return "cancelled by the app"
        }
        // Everything else, printed as itself.
        //
        // Bridging to `NSError` was the wrong default and is what produced
        // "GRPCCore.RuntimeError 1: Не удалось завершить операцию": a Swift
        // error that is a struct rather than an enum gets code 1 and a
        // localised nothing, discarding every field it carries. Reflection
        // prints the fields, so an unrecognised error still says what it is.
        return "\(type(of: error)): \(String(reflecting: error))"
    }
}
