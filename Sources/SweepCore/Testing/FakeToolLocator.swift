import Foundation

/// Pretends the given tools are installed: Apple tools under /usr/bin, everything else under /opt/homebrew/bin.
public struct FakeToolLocator: ToolLocating {
    public let tools: Set<String>
    public init(_ tools: [String]) { self.tools = Set(tools) }
    public func path(for tool: String) -> String? {
        guard tools.contains(tool) else { return nil }
        return ["xcrun", "git", "osascript", "pkgutil"].contains(tool) ? "/usr/bin/\(tool)" : "/opt/homebrew/bin/\(tool)"
    }
}
