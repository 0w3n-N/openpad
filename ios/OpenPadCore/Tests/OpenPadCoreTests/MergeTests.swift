import XCTest
@testable import OpenPadCore

final class MergeTests: XCTestCase {
    struct Vectors: Decodable {
        struct Case: Decodable {
            let a: Notebook
            let b: Notebook
            let expect: Expect
        }
        struct Expect: Decodable {
            let digest: String
            let order: [String]
            let title: String
            let goneP: [String]
            let pages: [String: ExpectPage]
        }
        struct ExpectPage: Decodable {
            let strokes: [String]
            let gone: [String]
            let paper: String
            let bg: Background?
            let t: Int64
        }
        let cases: [Case]
    }

    func vectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "merge_vectors", withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testMergeMatchesPython() throws {
        let v = try vectors()
        XCTAssertEqual(v.cases.count, 40)
        for (i, c) in v.cases.enumerated() {
            for m in [merge(c.a, c.b), merge(c.b, c.a)] {
                XCTAssertEqual(digest(m), c.expect.digest, "case \(i): digest")
                XCTAssertEqual(m.order, c.expect.order, "case \(i): order")
                XCTAssertEqual(m.title, c.expect.title, "case \(i): title")
                XCTAssertEqual(m.goneP, c.expect.goneP, "case \(i): deleted pages")
                XCTAssertEqual(Set(m.pages.keys), Set(c.expect.pages.keys), "case \(i): pages")
                for (id, want) in c.expect.pages {
                    let p = try XCTUnwrap(m.pages[id])
                    XCTAssertEqual(p.strokes.map(\.id), want.strokes, "case \(i) page \(id): strokes")
                    XCTAssertEqual(p.gone, want.gone, "case \(i) page \(id): gone")
                    XCTAssertEqual(p.paper, want.paper, "case \(i) page \(id): paper")
                    XCTAssertEqual(p.bg, want.bg, "case \(i) page \(id): background")
                    XCTAssertEqual(p.t, want.t, "case \(i) page \(id): t")
                }
            }
        }
    }

    func testMergeIsIdempotent() throws {
        for c in try vectors().cases {
            let m = merge(c.a, c.b)
            XCTAssertEqual(merge(m, m), m)
        }
    }

    func testDigestOfDecodedAndReencoded() throws {
        // Saving and loading a notebook must not change its digest.
        for c in try vectors().cases {
            let data = try JSONEncoder().encode(c.a)
            let back = try JSONDecoder().decode(Notebook.self, from: data)
            XCTAssertEqual(digest(back), digest(c.a))
            XCTAssertEqual(back, c.a)
        }
    }

    func testSHA256() {
        XCTAssertEqual(sha256Hex(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(PortableSHA256.hash(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = [UInt8](repeating: 0x61, count: 1_000_000)
        XCTAssertEqual(PortableSHA256.hash(long).map { String(format: "%02x", $0) }.joined(),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testPairingCode() {
        let key = "1os1-qB2tRVJBUzrkYBOVQ"
        XCTAssertEqual(PairingCode("http://192.168.1.17:8770/app?k=\(key)"), PairingCode("http://192.168.1.17:8770/?k=\(key)"))
        XCTAssertEqual(PairingCode("http://192.168.1.17:8770/app?k=\(key)")?.host, "192.168.1.17:8770")
        XCTAssertNil(PairingCode("https://example.com/app?k=\(key)"))
        XCTAssertNil(PairingCode("http://192.168.1.17:8770/join#w=\(key)"))
        XCTAssertNil(PairingCode("http://192.168.1.17:8770/app?k=short"))
        XCTAssertNil(PairingCode("http://192.168.1.17:8770/app?k=\(key)%0A"))
    }

    func testPartialMergeAddsAPage() throws {
        var nb = newNotebook(title: "T", size: .letter)
        let sec = nb.layout.sections[0]
        let p = blankPage(section: sec.id, size: .letter, paper: "grid")
        var edited = nb
        edited.pages[p.id] = p
        edited.layout = Layout(t: nb.layout.t + 1, sections: [Section(id: sec.id, title: sec.title, pages: sec.pages + [p.id])])
        let part = partial(edited, layout: true, pages: [p.id])
        nb = mergePartial(nb, part)
        XCTAssertEqual(nb.order.last, p.id)
        XCTAssertEqual(nb.pages[p.id]?.paper, "grid")
        XCTAssertEqual(nb.title, "T")
    }

    func testLiveOps() {
        var nb = newNotebook(title: "T", size: .letter)
        let pid = nb.order[0]
        let s = Stroke(id: "s1", z: 1, tool: "pen", color: "#111111", width: 3.5, pts: [[1, 2, 0.5]])
        apply(.begin(page: pid, stroke: s), to: &nb)
        apply(.points(stroke: "s1", pts: [[3, 4, 0.5]]), to: &nb)
        XCTAssertEqual(nb.pages[pid]?.strokes.first?.pts.count, 2)
        apply(.remove(page: pid, ids: ["s1"]), to: &nb)
        XCTAssertEqual(nb.pages[pid]?.gone, ["s1"])
        apply(.restore(page: pid, strokes: [s]), to: &nb)  // a removed id never comes back
        XCTAssertTrue(nb.pages[pid]?.strokes.isEmpty ?? false)
    }
}
