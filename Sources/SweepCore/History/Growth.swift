import Foundation

public struct SeriesPoint: Sendable, Hashable, Codable {
    public var date: Date
    public var bytes: Int64
    public init(date: Date, bytes: Int64) { self.date = date; self.bytes = bytes }
}

public enum Growth {
    /// Least-squares slope in bytes/day, using only points after the last big drop (a cleanup resets the trend).
    public static func ratePerDay(_ series: [SeriesPoint]) -> Double? {
        let s = series.sorted { $0.date < $1.date }
        var start = 0
        for i in s.indices.dropFirst() where Double(s[i].bytes) < Double(s[i - 1].bytes) * 0.8 { start = i }
        return slope(Array(s[start...]))
    }

    /// Days until free space hits zero at the current trend; nil if free space isn't shrinking.
    public static func daysToFull(freeSeries: [SeriesPoint]) -> Double? {
        let s = freeSeries.sorted { $0.date < $1.date }
        guard let m = slope(s), m < 0, let last = s.last else { return nil }
        return Double(last.bytes) / -m
    }

    static func slope(_ s: [SeriesPoint]) -> Double? {
        guard s.count >= 2, let t0 = s.first?.date else { return nil }
        let xs = s.map { $0.date.timeIntervalSince(t0) / 86400 }, ys = s.map { Double($0.bytes) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let den = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        guard den > 1e-9 else { return nil }
        return zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / den
    }
}
