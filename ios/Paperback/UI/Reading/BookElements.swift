import UIKit

/// What every element of the reading screen shares: the unit it stands for, and the book view that owns it.
@MainActor
protocol BookElement: AnyObject {
	var unit: Int { get }
	var bookView: BookView? { get }
}

/// One VoiceOver element per paragraph, heading, or image. Instances are cheap and disposable: equality and hashing
/// are by unit, so VoiceOver treats a re-created element as the one it saw before the window let it go.
@MainActor
final class ParagraphElement: UIAccessibilityElement, BookElement {
	let unit: Int
	weak var bookView: BookView?
	private let isWholeLink: Bool
	/// UIKit holds an element's container weakly, and the book view may let a list go while VoiceOver is still in it.
	private let list: ListElement?

	init(container: Any, bookView: BookView, unit index: Int, unit: BookUnit) {
		self.unit = index
		self.bookView = bookView
		isWholeLink = unit.isWholeLink
		list = container as? ListElement
		super.init(accessibilityContainer: container)
		switch unit.kind {
		case .heading(let level):
			accessibilityAttributedLabel = NSAttributedString(string: unit.text, attributes: [.accessibilityTextHeadingLevel: level])
			accessibilityTraits = .header
		case .image(let description):
			// TRANSLATORS: Spoken for an image in a book that has no description
			accessibilityLabel = description ?? t("Image")
			accessibilityTraits = description == nil ? .staticText : .image
		case .paragraph, .listItem, .caption, .tableRow:
			accessibilityLabel = unit.text
			accessibilityTraits = .staticText
		}
		if isWholeLink { accessibilityTraits.insert(.link) }
	}

	nonisolated override func isEqual(_ object: Any?) -> Bool {
		(object as? ParagraphElement)?.unit == unit
	}

	nonisolated override var hash: Int { unit }

	/// Computed on demand so the frame always matches the page now showing.
	override var accessibilityFrame: CGRect {
		get {
			guard let bookView else { return .zero }
			return UIAccessibility.convertToScreenCoordinates(bookView.frame(forUnit: unit), in: bookView)
		}
		set {}
	}

	override func accessibilityElementDidBecomeFocused() {
		bookView?.unitBecameFocused(unit)
	}

	/// Double-tap opens the in-book menu, except on a paragraph that is one link, where it follows the link.
	override func accessibilityActivate() -> Bool {
		guard let bookView else { return false }
		if isWholeLink {
			bookView.onFollowLink?(unit, 0)
		} else {
			bookView.onActivate?()
		}
		return true
	}
}

/// A link inside a paragraph, which the Links rotor lands on. It is not one of the container's own elements, so a
/// flick from it moves on from its paragraph, and the paragraph stays one flick however many links it holds.
@MainActor
final class LinkElement: UIAccessibilityElement, BookElement {
	let unit: Int
	let link: Int
	weak var bookView: BookView?
	/// UIKit holds an element's container weakly, and the book view may let a list go while VoiceOver is still in it.
	private let list: ListElement?

	init(container: Any, bookView: BookView, unit: Int, link: Int, text: String) {
		self.unit = unit
		self.link = link
		self.bookView = bookView
		list = container as? ListElement
		super.init(accessibilityContainer: container)
		accessibilityLabel = text
		accessibilityTraits = .link
	}

	nonisolated override func isEqual(_ object: Any?) -> Bool {
		guard let other = object as? LinkElement else { return false }
		return other.unit == unit && other.link == link
	}

	nonisolated override var hash: Int { unit &* 1024 &+ link }

	override var accessibilityFrame: CGRect {
		get {
			guard let bookView else { return .zero }
			return UIAccessibility.convertToScreenCoordinates(bookView.frame(forUnit: unit), in: bookView)
		}
		set {}
	}

	override func accessibilityElementDidBecomeFocused() {
		bookView?.unitBecameFocused(unit)
	}

	override func accessibilityActivate() -> Bool {
		bookView?.onFollowLink?(unit, link)
		return true
	}
}

/// A list, which VoiceOver announces on entry and whose items are one flick each.
@MainActor
final class ListElement: UIAccessibilityElement {
	let block: Int
	private let units: Range<Int>
	weak var bookView: BookView?

	init(bookView: BookView, block: Int, units: Range<Int>) {
		self.block = block
		self.units = units
		self.bookView = bookView
		super.init(accessibilityContainer: bookView)
		isAccessibilityElement = false
		accessibilityContainerType = .list
		// TRANSLATORS: Spoken on entering a list in a book; {} is how many items it has. Which of the three forms is used depends on the language's plural rule, and the "many" form's trailing character isn't a typo.
		accessibilityLabel = nt(t("{} item"), t("{} items"), t("{} items⁣"), units.count).replacingOccurrences(of: "{}", with: "\(units.count)")
	}

	nonisolated override func isEqual(_ object: Any?) -> Bool {
		(object as? ListElement)?.block == block
	}

	nonisolated override var hash: Int { block }

	override var accessibilityFrame: CGRect {
		get {
			guard let bookView else { return .zero }
			return UIAccessibility.convertToScreenCoordinates(bookView.frame(forUnits: units), in: bookView)
		}
		set {}
	}

	override func accessibilityElementCount() -> Int {
		units.count
	}

	override func accessibilityElement(at index: Int) -> Any? {
		bookView?.element(forUnit: units.lowerBound + index)
	}

	override func index(ofAccessibilityElement element: Any) -> Int {
		guard let unit = (element as? BookElement)?.unit, units.contains(unit) else { return NSNotFound }
		return unit - units.lowerBound
	}
}

/// A table as VoiceOver's data table: it announces rows and columns on entry, flicking moves cell by cell, and the row
/// and column headers are spoken when they change.
@MainActor
final class TableElement: UIAccessibilityElement, @preconcurrency UIAccessibilityContainerDataTable {
	let block: Int
	let table: ParsedTable
	/// The first row's unit; row r is unit `firstUnit + r`.
	let firstUnit: Int
	weak var bookView: BookView?
	/// Every cell in reading order, as its row and its index among the cells starting in that row.
	private let order: [(row: Int, cell: Int)]

	init(bookView: BookView, block: Int, table: ParsedTable, firstUnit: Int) {
		self.block = block
		self.table = table
		self.firstUnit = firstUnit
		self.bookView = bookView
		order = table.rows.enumerated().flatMap { row, cells in cells.indices.map { (row, $0) } }
		super.init(accessibilityContainer: bookView)
		isAccessibilityElement = false
		accessibilityContainerType = .dataTable
	}

	nonisolated override func isEqual(_ object: Any?) -> Bool {
		(object as? TableElement)?.block == block
	}

	nonisolated override var hash: Int { block }

	override var accessibilityFrame: CGRect {
		get {
			guard let bookView else { return .zero }
			return UIAccessibility.convertToScreenCoordinates(bookView.frame(forUnits: firstUnit..<firstUnit + table.rowCount), in: bookView)
		}
		set {}
	}

	private func element(_ cell: ParsedTable.Cell) -> TableCellElement? {
		bookView?.cellElement(row: cell.row, column: cell.column, table: self)
	}

	override func accessibilityElementCount() -> Int {
		order.count
	}

	override func accessibilityElement(at index: Int) -> Any? {
		guard order.indices.contains(index) else { return nil }
		return element(table.rows[order[index].row][order[index].cell])
	}

	override func index(ofAccessibilityElement element: Any) -> Int {
		guard let cell = element as? TableCellElement else { return NSNotFound }
		return order.firstIndex { table.rows[$0.row][$0.cell].column == cell.column && $0.row == cell.row } ?? NSNotFound
	}

	func accessibilityDataTableCellElement(forRow row: Int, column: Int) -> (any UIAccessibilityContainerDataTableCell)? {
		table.cell(row: row, column: column).flatMap(element)
	}

	func accessibilityRowCount() -> Int {
		table.rowCount
	}

	func accessibilityColumnCount() -> Int {
		table.columnCount
	}

	func accessibilityHeaderElements(forRow row: Int) -> [any UIAccessibilityContainerDataTableCell]? {
		table.rowHeaders(row).compactMap(element)
	}

	func accessibilityHeaderElements(forColumn column: Int) -> [any UIAccessibilityContainerDataTableCell]? {
		table.columnHeaders(column).compactMap(element)
	}
}

/// One cell of a table.
@MainActor
final class TableCellElement: UIAccessibilityElement, BookElement, @preconcurrency UIAccessibilityContainerDataTableCell {
	let row: Int
	let column: Int
	private let rowSpan: Int
	private let columnSpan: Int
	private let columnCount: Int
	/// The unit of the row the cell starts in.
	let unit: Int
	weak var bookView: BookView?
	/// UIKit holds an element's container weakly, and the book view may let a table go while VoiceOver is still in it.
	private let table: TableElement

	init(table: TableElement, cell: ParsedTable.Cell, bookView: BookView) {
		self.table = table
		row = cell.row
		column = cell.column
		rowSpan = cell.rowSpan
		columnSpan = cell.columnSpan
		columnCount = table.table.columnCount
		unit = table.firstUnit + cell.row
		self.bookView = bookView
		super.init(accessibilityContainer: table)
		// TRANSLATORS: Spoken for an empty table cell
		accessibilityLabel = cell.text.isEmpty ? t("Blank") : cell.text
		accessibilityTraits = .staticText
	}

	nonisolated override func isEqual(_ object: Any?) -> Bool {
		guard let other = object as? TableCellElement else { return false }
		return other.unit == unit && other.column == column
	}

	nonisolated override var hash: Int { unit &* 1024 &+ column }

	override var accessibilityFrame: CGRect {
		get {
			guard let bookView else { return .zero }
			return UIAccessibility.convertToScreenCoordinates(bookView.frame(forCellAt: column, span: columnSpan, of: columnCount, rows: unit..<unit + rowSpan), in: bookView)
		}
		set {}
	}

	func accessibilityRowRange() -> NSRange {
		NSRange(location: row, length: rowSpan)
	}

	func accessibilityColumnRange() -> NSRange {
		NSRange(location: column, length: columnSpan)
	}

	override func accessibilityElementDidBecomeFocused() {
		bookView?.unitBecameFocused(unit)
	}

	override func accessibilityActivate() -> Bool {
		bookView?.onActivate?()
		return true
	}
}
