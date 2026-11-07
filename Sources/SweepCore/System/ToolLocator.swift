import Foundation

/// Resolves tool names to absolute paths without consulting a shell.
public protocol ToolLocating: Sendable {
    func path(for tool: String) -> String?
}

public struct ToolLocator: ToolLocating {
    public let searchPaths: [String]

    public init(searchPaths: [String]? = nil, home: String = NSHomeDirectory()) {
        self.searchPaths = searchPaths ?? [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/.local/bin",
            "/Applications/Docker.app/Contents/Resources/bin", "/opt/homebrew/sbin",
        ]
    }

    public func path(for tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
