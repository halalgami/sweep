import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk). Rects are returned in input order.
public enum Treemap {
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        guard !values.isEmpty else { return [] }
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let order = values.indices.sorted { values[$0] > values[$1] }
        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var row: [Int] = []

        func worst(_ row: [Int], _ side: Double) -> Double {
            let areas = row.map { values[$0] * scale }
            let s = areas.reduce(0, +)
            guard s > 0, let mx = areas.max(), let mn = areas.min(), mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }
        func layout(_ row: [Int]) {
            let s = row.reduce(0) { $0 + values[$1] * scale }
            if remaining.width >= remaining.height {
                let w = CGFloat(s / Double(remaining.height))
                var y = remaining.minY
                for i in row {
                    let h = CGFloat(values[i] * scale) / w
                    result[i] = CGRect(x: remaining.minX, y: y, width: w, height: h); y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY, width: max(0, remaining.width - w), height: remaining.height)
            } else {
                let h = CGFloat(s / Double(remaining.width))
                var x = remaining.minX
                for i in row {
                    let w = CGFloat(values[i] * scale) / h
                    result[i] = CGRect(x: x, y: remaining.minY, width: w, height: h); x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: max(0, remaining.height - h))
            }
        }
        for i in order where values[i] > 0 {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [i], side) <= worst(row, side) { row.append(i) }
            else { layout(row); row = [i] }
        }
        if !row.isEmpty { layout(row) }
        return result
    }
}
