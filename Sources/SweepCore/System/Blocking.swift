import Foundation

/// Runs blocking work (filesystem walks, sizing) on a Dispatch queue instead of Swift's cooperative thread pool,
/// which has one thread per core and stalls every other task while a long walk holds one of them.
enum Blocking {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: work()) }
        }
    }
}
