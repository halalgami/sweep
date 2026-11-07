import Foundation

public struct LSRecord: Sendable, Hashable {
    public var path: String
    public var identifier: String
    public var name: String
}

/// Parses `lsregister -dump`. Records are delimited by dashed lines; fields are paired within one record only.
public enum LSRegisterParser {
    public static func records(_ dump: String) -> [LSRecord] {
        var out: [LSRecord] = []
        var path: String?, ident: String?, name: String?
        func flush() {
            if let path, let ident { out.append(LSRecord(path: path, identifier: ident, name: name ?? (path as NSString).lastPathComponent)) }
            path = nil; ident = nil; name = nil
        }
        for raw in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.count >= 20, line.allSatisfy({ $0 == "-" }) { flush(); continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let r = value.range(of: #" \(0x[0-9a-fA-F]+\)$"#, options: .regularExpression) { value.removeSubrange(r) }
            switch key {
            case "path": path = value
            case "identifier": ident = value
            case "name": name = value
            default: break
            }
        }
        flush()
        return out
    }
}
