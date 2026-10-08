import XCTest
@testable import Paperback

/// Real books from the fixture folder, skipped when it is absent (any machine but Rashad's Mac).
@MainActor
final class FixtureBookTests: XCTestCase {
	private func open(_ name: String) throws -> DocumentSession {
		let path = NSHomeDirectory().components(separatedBy: "/Library/Developer").first! + "/Documents/home/books/\(name)"
		try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "fixture books not present")
		return try DocumentSession.newFfi(filePath: path, password: "", forcedExtension: "", renderTablesInline: false)
	}

	func testWarAndPeaceOpensQuicklyAndEveryUnitMapsBackToItself() throws {
		let session = try open("War_and_Peace_rashad_naqeeb.epub")
		let start = Date()
		let model = BookModel(session: session)
		let elapsed = Date().timeIntervalSince(start)
		print("War and Peace: \(model.count) units, \(model.headingUnits.count) headings, \(model.linkStops.count) links in \(elapsed) s")
		XCTAssertGreaterThan(model.count, 10_000)
		XCTAssertGreaterThan(model.headingUnits.count, 300)
		XCTAssertLessThan(elapsed, 3)
		for unit in stride(from: 0, to: model.count, by: 97) {
			XCTAssertEqual(model.unit(forPosition: model.position(ofUnit: unit)), unit)
		}
	}

	func testThePrizesLinksLandOnTheirText() throws {
		var start = Date()
		let session = try open("The_Prize_rashad_naqeeb.epub")
		let parsed = Date().timeIntervalSince(start)
		start = Date()
		let model = BookModel(session: session)
		print("The Prize: parsed in \(parsed) s, model in \(Date().timeIntervalSince(start)) s")
		XCTAssertGreaterThan(model.linkStops.count, 1000)
		var mismatches = 0
		for stop in model.linkStops {
			let unit = model.units[stop.unit]
			let link = unit.links[stop.link]
			if String(unit.text[link.range]) != link.text { mismatches += 1 }
		}
		XCTAssertEqual(mismatches, 0)
		XCTAssertGreaterThan(model.imageUnits.count, 50)
		// Nested lists fold into the list holding them, so there are fewer lists than list markers, but every item is in one.
		XCTAssertGreaterThan(model.listUnits.count, 50)
		XCTAssertGreaterThan(model.units.filter { $0.kind == .listItem }.count, 4000)
		// The Prize's four tables: an author page and three data tables.
		XCTAssertEqual(model.tables.count, 4)
		XCTAssertTrue(model.tables.contains { $0.caption.hasPrefix("German Oil Supply") && $0.columnCount == 5 })
	}
}
