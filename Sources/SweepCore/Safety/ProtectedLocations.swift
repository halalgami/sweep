import Foundation

/// Places Sweep never touches: cloud-synced folders, Keychains, Mail/Messages, system paths, user-protected paths.
public struct ProtectedLocations: Sendable {
    public let home: String
    public let userProtected: [String]
    public let iCloudDesktopAndDocuments: Bool

    public init(home: String, userProtected: [String], iCloudDesktopAndDocuments: Bool? = nil) {
        self.home = home
        self.userProtected = userProtected.map { PathPattern.expandHome($0, home: home) }
        self.iCloudDesktopAndDocuments = iCloudDesktopAndDocuments ?? Self.finderSyncsDesktopAndDocuments()
    }

    /// Finder's "Desktop & Documents Folders" iCloud setting.
    public static func finderSyncsDesktopAndDocuments() -> Bool {
        let finder = UserDefaults(suiteName: "com.apple.finder")
        return finder?.bool(forKey: "FXICloudDriveDesktop") == true || finder?.bool(forKey: "FXICloudDriveDocuments") == true
    }

    public var cloudRoots: [String] {
        var roots = ["\(home)/Library/Mobile Documents", "\(home)/Library/CloudStorage", "\(home)/Dropbox", "\(home)/OneDrive",
                     "\(home)/Google Drive", "\(home)/Box"]
        if iCloudDesktopAndDocuments { roots += ["\(home)/Desktop", "\(home)/Documents"] }
        return roots
    }

    public var neverTouch: [String] {
        ["\(home)/Library/Keychains", "\(home)/Library/Mail", "\(home)/Library/Messages", "\(home)/Library/Containers/com.apple.mail",
         "\(home)/Library/Group Containers/group.com.apple.notes", "\(home)/Library/Safari", "\(home)/Library/Photos",
         "\(home)/Pictures/Photos Library.photoslibrary", "/System", "/bin", "/sbin", "/usr", "/private/etc", "/Library/Apple"]
    }

    /// Bucket roots and the home folder itself must never be removed wholesale.
    public var wholeRoots: Set<String> {
        Set(VolumeAccounting.defaultRoots(home: home) + ["/", "/Users", "/Library", "/private", "/private/var",
            "\(home)/Library", "\(home)/Documents", "\(home)/Desktop", "\(home)/Downloads", "\(home)/Library/Caches",
            "\(home)/Library/Application Support", "\(home)/.cache", "\(home)/Library/Containers"])
    }

    /// Why `path` is off limits, or nil if it's fine. `path` should already be symlink-resolved.
    public func reason(for path: String) -> String? {
        func inside(_ root: String) -> Bool { path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        if let r = userProtected.first(where: inside) { return "It's inside your protected folder \(r.replacingOccurrences(of: home, with: "~"))" }
        if cloudRoots.contains(where: inside) || path.hasPrefix("\(home)/OneDrive") { return "It's in a cloud-synced folder, which Sweep never touches" }
        if let r = neverTouch.first(where: inside), !(r == "/usr" && inside("/usr/local")) { return "Sweep never touches \(r.replacingOccurrences(of: home, with: "~"))" }
        if wholeRoots.contains(path) { return "Sweep never removes a whole top-level folder" }
        // Removing a folder removes everything in it, so a protected place *inside* the item blocks it too.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        if let r = (userProtected + cloudRoots + neverTouch).first(where: { $0.hasPrefix(prefix) }) {
            return "It contains \(r.replacingOccurrences(of: home, with: "~")), which Sweep never touches"
        }
        return nil
    }
}
