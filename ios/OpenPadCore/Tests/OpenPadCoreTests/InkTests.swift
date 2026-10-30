import XCTest
@testable import OpenPadCore

/// The ink geometry matches web/ink.js and web/editor.js.
final class InkTests: XCTestCase {
    private func stroke(_ pts: [[Double]], width: Double = 4) -> Stroke {
        Stroke(id: "s", z: 1, tool: "pen", color: "#111111", width: width, pts: pts)
    }

    func testPressure() {
        XCTAssertEqual(Ink.pressureWidth(4, Ink.neutralPressure), 4, accuracy: 1e-9)
        XCTAssertEqual(Ink.pressureWidth(4, 0), 1.4, accuracy: 1e-9)
        XCTAssertEqual(Ink.pressureWidth(4, 1), 6, accuracy: 1e-9)
        // Sensitivity 0: always the base width, whatever the Pencil says.
        XCTAssertEqual(Ink.shapePressure(1, sensitivity: 0, previous: nil), Ink.neutralPressure, accuracy: 1e-9)
        XCTAssertEqual(Ink.shapePressure(1, sensitivity: 1, previous: nil), 1, accuracy: 1e-9)
        // Smoothed: a jump moves 35% of the way.
        XCTAssertEqual(Ink.shapePressure(1, sensitivity: 1, previous: 0.5), 0.675, accuracy: 1e-9)
    }

    func testHit() {
        let s = stroke([[0, 0, 0.5], [100, 0, 0.5]])
        XCTAssertTrue(Ink.hit(s, x: 50, y: 8, r: 6))  // 6 + half the width
        XCTAssertFalse(Ink.hit(s, x: 50, y: 9, r: 6))
        XCTAssertFalse(Ink.hit(s, x: 120, y: 0, r: 6))
        XCTAssertTrue(Ink.hit(stroke([[10, 10, 0.5]]), x: 14, y: 10, r: 2))
    }

    func testLasso() {
        let square = [[0.0, 0.0], [100, 0], [100, 100], [0, 100]]
        XCTAssertTrue(Ink.inside(50, 50, polygon: square))
        XCTAssertFalse(Ink.inside(150, 50, polygon: square))
        XCTAssertTrue(Ink.lassoed(stroke([[10, 10, 0.5], [20, 20, 0.5], [200, 200, 0.5]]), polygon: square))
        XCTAssertFalse(Ink.lassoed(stroke([[10, 10, 0.5], [200, 200, 0.5], [300, 300, 0.5]]), polygon: square))
    }

    func testShapes() {
        let line = Ink.shapePoints(.line, from: [0, 0, 0.5], to: [120, 0, 0.5])
        XCTAssertEqual(line.count, 11)
        XCTAssertEqual(line.last.map { [$0[0], $0[1]] }, [120, 0])
        XCTAssertTrue(line.allSatisfy { $0[2] == Ink.neutralPressure })
        let rect = Ink.shapePoints(.rect, from: [10, 20, 0.5], to: [30, 40, 0.5])
        XCTAssertEqual(rect.map { [$0[0], $0[1]] },
                       [[10, 20], [30, 20], [30, 20], [30, 40], [30, 40], [10, 40], [10, 40], [10, 20], [10, 20]])
        let ellipse = Ink.shapePoints(.ellipse, from: [0, 0, 0.5], to: [100, 50, 0.5])
        XCTAssertEqual(ellipse.count, 27)  // n = max(24, round(75 / 3)) = 25, plus 2
        XCTAssertEqual(ellipse.first.map { [$0[0], $0[1]] }, [100, 25])
        let arrow = Ink.shapePoints(.arrow, from: [0, 0, 0.5], to: [100, 0, 0.5])
        XCTAssertEqual(arrow.suffix(3).map { $0[0] }, [Ink.round2(100 - 28 * cos(-0.45)), 100, Ink.round2(100 - 28 * cos(0.45))])
        XCTAssertEqual(Ink.shapePoints(.axes, from: [50, 50, 0.5], to: [150, -50, 0.5]).count, 13)
    }

    func testReid() {
        let a = stroke([[1, 2, 0.5]])
        let b = Ink.reid([a])[0]
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.pts, b.pts)
    }
}
