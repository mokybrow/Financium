import Foundation
import GRPCCore
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
enum FinanceLog {
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
    /// gRPC failures are unwrapped to code and server message — the message is
    /// the useful half and is the part `localizedDescription` throws away. A
    /// cancellation is named as such rather than reported as a fault, because
    /// it usually means the app called the request off itself.
    static func describe(_ error: Error) -> String {
        if let rpc = error as? RPCError {
            let message = rpc.message.isEmpty ? "no message" : rpc.message
            return "grpc \(rpc.code): \(message)"
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
