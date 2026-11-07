import CoreGraphics
import Testing
@testable import SweepCore

@Suite struct TreemapTests {
    @Test func areasProportionalAndInsideBounds() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let values: [Double] = [500, 250, 120, 80, 30, 20]
        let rects = Treemap.squarify(values, in: rect)
        #expect(rects.count == values.count)
        let total = values.reduce(0, +)
        for (r, v) in zip(rects, values) {
            #expect(abs(r.width * r.height / (rect.width * rect.height) - v / total) < 0.005)
            #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(r))
        }
    }

    @Test func emptyAndZeroInputs() {
        #expect(Treemap.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        let r = Treemap.squarify([0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(r.count == 2)
    }
}
