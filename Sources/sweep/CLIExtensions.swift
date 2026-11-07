import Foundation
import SweepCore

/// Commands added by later milestones (plan/run).
enum CLIExtensions {
    static func handle(command: String, args: inout Arguments) async -> Bool { false }
}
