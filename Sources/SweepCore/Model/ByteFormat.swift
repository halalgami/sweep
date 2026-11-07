import Foundation

/// Decimal (SI) byte formatting, matching Finder: 1 GB = 1,000,000,000 bytes.
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(abs(bytes))
        var idx = 0
        while value >= 1000, idx < units.count - 1 { value /= 1000; idx += 1 }
        let sign = bytes < 0 ? "-" : ""
        if idx == 0 { return "\(sign)\(Int(value)) bytes" }
        if idx == 1 { return "\(sign)\(Int(value.rounded())) KB" }
        return "\(sign)\(String(format: "%.1f", value)) \(units[idx])"
    }

    /// Short form for tight UI ("38.6 GB" → "38.6 GB", but per-day rates use this too).
    public static func rate(_ bytesPerDay: Double) -> String {
        let s = string(Int64(bytesPerDay.rounded()))
        return (bytesPerDay >= 0 ? "+" : "") + s + "/day"
    }
}
