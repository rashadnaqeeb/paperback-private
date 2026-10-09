import UIKit
import XCTest
@testable import Paperback

final class TableParserTests: XCTestCase {
	func testHeaderCellsCaptionAndEntitiesComeThrough() throws {
		let table = try XCTUnwrap(TableParser.parse("""
		<table><caption> German Oil <span>(barrels &amp; tons)</span></caption>
		<tr><th>Year</th><th>Synthetic</th></tr>
		<tr><td>1938</td><td>22&#160;000</td></tr>
		<tr><td>1939</td><td>28,000</td></tr></table>
		"""))
		XCTAssertEqual(table.caption, "German Oil (barrels & tons)")
		XCTAssertEqual(table.rowCount, 3)
		XCTAssertEqual(table.columnCount, 2)
		XCTAssertEqual(table.headerRowCount, 1)
		// A no-break space is whitespace like any other once the cell is read as text.
		XCTAssertEqual(table.cell(row: 1, column: 1)?.text, "22 000")
		XCTAssertEqual(table.columnHeaders(1).map(\.text), ["Synthetic"])
	}

	func testSpansPlaceLaterCellsInTheFreeColumns() throws {
		let table = try XCTUnwrap(TableParser.parse("""
		<table><tr><th colspan="2">Title</th></tr>
		<tr><td rowspan=2>A</td><td>B</td></tr>
		<tr><td>C</td></tr></table>
		"""))
		XCTAssertEqual(table.columnCount, 2)
		XCTAssertEqual(table.cell(row: 0, column: 1)?.text, "Title")
		XCTAssertEqual(table.cell(row: 2, column: 0)?.text, "A")
		XCTAssertEqual(table.cell(row: 2, column: 1)?.text, "C")
	}

	func testWithNoHeaderCellsTheFirstRowNamesTheColumns() throws {
		let table = try XCTUnwrap(TableParser.parse("<table><tr><td>Name</td><td>Age</td></tr><tr><td>Ann</td><td>9</td></tr></table>"))
		XCTAssertEqual(table.headerRowCount, 1)
		XCTAssertEqual(table.columnHeaders(1).map(\.text), ["Age"])
	}

	func testARowStartingWithAHeaderCellIsNamedByIt() throws {
		let table = try XCTUnwrap(TableParser.parse("<table><thead><tr><td></td><td>2020</td></tr></thead><tr><th>Oil</th><td>5</td></tr></table>"))
		XCTAssertEqual(table.headerRowCount, 1)
		XCTAssertEqual(table.rowHeaders(1).map(\.text), ["Oil"])
	}

	func testAHeaderRowMayStartWithAnEmptyCorner() throws {
		let table = try XCTUnwrap(TableParser.parse("<table><tr><td></td><th>2019</th><th>2020</th></tr><tr><th>Revenue</th><td>5</td><td>6</td></tr></table>"))
		XCTAssertEqual(table.headerRowCount, 1)
		XCTAssertEqual(table.columnHeaders(2).map(\.text), ["2020"])
		XCTAssertEqual(table.rowHeaders(1).map(\.text), ["Revenue"])
	}

	func testSpanAttributesAreReadWholeAndWithSpaces() throws {
		let table = try XCTUnwrap(TableParser.parse("<table><tr><td colspan = \"2\">A</td><td data-colspan=\"5\">B</td></tr><tr><td>c</td><td>d</td><td>e</td></tr></table>"))
		XCTAssertEqual(table.columnCount, 3)
		XCTAssertEqual(table.cell(row: 0, column: 2)?.text, "B")
	}

	func testAbsurdSpansAreBounded() throws {
		let table = try XCTUnwrap(TableParser.parse("<table><tr><td colspan=\"999999999\" rowspan=\"9999999\">A</td></tr><tr><td>b</td></tr></table>"))
		XCTAssertEqual(table.cell(row: 0, column: 0)?.columnSpan, 50)
		XCTAssertEqual(table.cell(row: 0, column: 0)?.rowSpan, 2)
	}

	func testATableOfOneCellIsNotATable() {
		XCTAssertNil(TableParser.parse("<table><tr><td>Just text</td></tr></table>"))
	}

	func testANestedTableIsOnlyText() throws {
		let table = try XCTUnwrap(TableParser.parse("<table><tr><td>a<table><tr><td>inner</td></tr></table></td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>"))
		XCTAssertEqual(table.columnCount, 2)
		XCTAssertEqual(table.cell(row: 0, column: 0)?.text, "a inner")
	}
}

/// A book given as its buffer and markers.
private final class MarkedSession: DocumentSession, @unchecked Sendable {
	var buffer = ""
	var markers: [LineMarker] = []
	var toc: [TocEntry] = []

	override func content() -> String { buffer }
	override func getStructureMarkersFfi() -> [LineMarker] { markers }
	override func getToc() -> [TocEntry] { toc }

	func mark(_ type: MarkerType, at position: Int64, length: Int64 = 0, text: String = "", reference: String = "") {
		markers.append(LineMarker(mtype: type, position: position, text: text, reference: reference, level: 0, length: length))
	}
}

@MainActor
final class ListAndTableTests: XCTestCase {
	// Lines start at 0, 6, 15, 23, 43, 49.
	private let buffer = "Intro\n• Apples\n• Pears\n[Table]: Year Sales\nOutro\nLast."
	private let tableHTML = "<table><caption>Sales</caption><tr><th>Year</th><th>Sales</th></tr><tr><td>2020</td><td>5</td></tr><tr><td>2021</td><td>7</td></tr></table>"

	private func model() -> BookModel {
		let session = MarkedSession(noHandle: .init())
		session.buffer = buffer
		session.mark(.list, at: 6, length: 17)
		session.mark(.listItem, at: 6)
		session.mark(.listItem, at: 15)
		session.mark(.table, at: 23, reference: tableHTML)
		return BookModel(session: session)
	}

	private func view() -> BookView {
		let view = BookView(model: model())
		view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
		view.layoutIfNeeded()
		return view
	}

	func testAListIsOneBlockOfItems() {
		let model = model()
		XCTAssertEqual(model.units[1].kind, .listItem)
		XCTAssertEqual(model.units[2].kind, .listItem)
		XCTAssertEqual(model.blocks[1].kind, .list)
		XCTAssertEqual(model.blocks[1].units, 1..<3)
	}

	func testATableIsItsCaptionThenABlockOfRows() {
		let model = model()
		XCTAssertEqual(model.units[3].kind, .caption)
		XCTAssertEqual(model.units[3].text, "Sales")
		XCTAssertEqual(model.blocks[2].units, 3..<4)
		XCTAssertEqual(model.blocks[3].kind, .table(0))
		XCTAssertEqual(model.blocks[3].units, 4..<7)
		XCTAssertEqual(model.tableUnits, [4])
		XCTAssertEqual(model.units[7].text, "Outro")
		// The table's line start is its caption's place; each row stands one position further in.
		XCTAssertEqual(model.unit(forPosition: 23), 3)
		XCTAssertEqual(model.unit(forPosition: 24), 4)
	}

	func testEachTableRowKeepsItsOwnPosition() {
		let model = model()
		for unit in 3..<7 {
			XCTAssertEqual(model.unit(forPosition: model.position(ofUnit: unit)), unit)
		}
		XCTAssertNotEqual(model.position(ofUnit: 4), model.position(ofUnit: 6))
	}

	func testATableInsideAListKeepsTheItemsAfterItInAList() {
		let session = MarkedSession(noHandle: .init())
		// Lines start at 0, 4, 15, 22.
		session.buffer = "• A\n[Table]: x\n• After\nOutro"
		session.mark(.list, at: 0, length: 22)
		session.mark(.table, at: 4, reference: tableHTML)
		let model = BookModel(session: session)
		XCTAssertEqual(model.blocks[0].kind, .list)
		let after = model.units.firstIndex { $0.text == "• After" }!
		XCTAssertEqual(model.units[after].kind, .listItem)
		XCTAssertEqual(model.blocks[model.blockOfUnit[after]].kind, .list)
		XCTAssertEqual(model.units.last?.kind, .paragraph)
	}

	func testAListStartingWithATableLeavesNoEmptyList() {
		let session = MarkedSession(noHandle: .init())
		session.buffer = "[Table]: x\n• After\nOutro"
		session.mark(.list, at: 0, length: 19)
		session.mark(.table, at: 0, reference: tableHTML)
		let model = BookModel(session: session)
		XCTAssertFalse(model.blocks.contains { $0.units.isEmpty })
		XCTAssertEqual(model.blocks.filter { $0.kind == .list }.count, 1)
	}

	func testTheBookViewsElementsAreTheBlocks() {
		let view = view()
		XCTAssertEqual(view.accessibilityElementCount(), 6)
		let list = view.accessibilityElement(at: 1) as? ListElement
		XCTAssertEqual(list?.accessibilityContainerType, .list)
		XCTAssertEqual(list?.accessibilityElementCount(), 2)
		let item = list?.accessibilityElement(at: 1) as? ParagraphElement
		XCTAssertEqual(item?.unit, 2)
		XCTAssertTrue(item?.accessibilityContainer as? ListElement === list)
		XCTAssertEqual(view.index(ofAccessibilityElement: item as Any), 1)
	}

	func testATableIsADataTableOfCellsWithHeaders() throws {
		let view = view()
		let table = try XCTUnwrap(view.accessibilityElement(at: 3) as? TableElement)
		XCTAssertEqual(table.accessibilityContainerType, .dataTable)
		XCTAssertEqual(table.accessibilityRowCount(), 3)
		XCTAssertEqual(table.accessibilityColumnCount(), 2)
		XCTAssertEqual(table.accessibilityElementCount(), 6)
		let cell = try XCTUnwrap(table.accessibilityDataTableCellElement(forRow: 2, column: 1) as? TableCellElement)
		XCTAssertEqual(cell.accessibilityLabel, "7")
		XCTAssertEqual(cell.accessibilityRowRange(), NSRange(location: 2, length: 1))
		XCTAssertEqual((table.accessibilityHeaderElements(forColumn: 1)?.first as? TableCellElement)?.accessibilityLabel, "Sales")
		XCTAssertEqual(table.index(ofAccessibilityElement: cell), 5)
		XCTAssertEqual(view.index(ofAccessibilityElement: table), 3)
	}

	func testCellsSitSideBySideInTheirRow() throws {
		let view = view()
		let table = try XCTUnwrap(view.accessibilityElement(at: 3) as? TableElement)
		let left = try XCTUnwrap(view.cellElement(row: 1, column: 0, table: table))
		let right = try XCTUnwrap(view.cellElement(row: 1, column: 1, table: table))
		let leftFrame = view.frame(forCellAt: 0, span: 1, of: 2, rows: left.unit..<left.unit + 1)
		let rightFrame = view.frame(forCellAt: 1, span: 1, of: 2, rows: right.unit..<right.unit + 1)
		XCTAssertEqual(leftFrame.minY, rightFrame.minY)
		XCTAssertEqual(leftFrame.maxX, rightFrame.minX, accuracy: 0.5)
		XCTAssertTrue(view.bounds.contains(leftFrame))
	}

	private func search(_ rotor: UIAccessibilityCustomRotor?, from element: Any?, forward: Bool = true) -> Any? {
		let predicate = UIAccessibilityCustomRotorSearchPredicate()
		predicate.searchDirection = forward ? .next : .previous
		predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: element as? NSObjectProtocol ?? NSObject(), targetRange: nil)
		return rotor?.itemSearchBlock(predicate)?.targetElement
	}

	func testTheTablesRotorStopsOncePerTableAndThereIsNoListsRotor() {
		let view = view()
		let tables = view.accessibilityCustomRotors?.first { $0.systemRotorType == .table }
		XCTAssertEqual((search(tables, from: view.element(forUnit: 0)) as? TableCellElement)?.unit, 4)
		XCTAssertFalse(view.accessibilityCustomRotors?.contains { $0.systemRotorType == .list } ?? true)
	}
}
