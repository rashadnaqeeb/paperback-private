import Foundation

/// A link inside a unit's text.
struct BookLink {
	/// The engine's marker position, which is what `activateLink` resolves.
	let position: Int64
	let text: String
	/// Where the link sits in the unit's text.
	let range: Range<String.Index>
}

enum UnitKind: Equatable {
	case paragraph
	case heading(level: Int)
	/// An image, with its description when the book gives one.
	case image(description: String?)
	case listItem
	/// A table's caption, its own element before the table.
	case caption
	/// One row of a table, laid out as a row and read cell by cell.
	case tableRow(table: Int, row: Int)
}

/// One thing the reading screen lays out as a piece: a paragraph, heading, image, list item, or caption, each one
/// non-blank line of the engine's buffer and one VoiceOver element; or a table row, whose table is one line.
struct BookUnit {
	let kind: UnitKind
	/// The 0-based buffer line.
	let line: Int
	let text: String
	let links: [BookLink]

	/// A paragraph that is nothing but one link, which double-tap follows instead of opening the menu.
	var isWholeLink: Bool {
		links.count == 1 && links[0].range == text.startIndex..<text.endIndex
	}
}

/// A top-level piece of the book: one unit, or a whole list or table. The Paragraphs rotor moves by blocks, so a list
/// or table is one step.
struct BookBlock {
	enum Kind: Equatable {
		case single
		case list
		case table(Int)
	}

	let kind: Kind
	var units: Range<Int>
}

/// The open book as the reading screen sees it: its units in reading order grouped into blocks, and the maps the
/// rotors move by. Built once when the book opens, from the buffer and one pass over the engine's markers.
@MainActor
final class BookModel {
	let session: DocumentSession
	private(set) var units: [BookUnit] = []
	private(set) var blocks: [BookBlock] = []
	/// The block each unit belongs to.
	private(set) var blockOfUnit: [Int] = []
	private(set) var tables: [ParsedTable] = []
	/// Where each buffer line starts, in the engine's positions (Unicode scalars on iOS).
	private let lineStarts: [Int64]
	/// The first unit on or after each buffer line, for mapping positions to units.
	private var unitAtLine: [Int] = []
	private(set) var headingUnits: [Int] = []
	private(set) var imageUnits: [Int] = []
	/// The first unit of each list and of each table, one rotor stop per structure.
	private(set) var listUnits: [Int] = []
	private(set) var tableUnits: [Int] = []
	/// Every link in reading order, as its unit and its index among that unit's links.
	private(set) var linkStops: [(unit: Int, link: Int)] = []

	init(session: DocumentSession) {
		self.session = session
		let bytes = Array(session.content().utf8)
		var starts: [Int64] = [0]
		var ranges: [Range<Int>] = []
		bytes.withUnsafeBufferPointer { buffer in
			var scalar: Int64 = 0
			var lineStart = 0
			for (offset, byte) in buffer.enumerated() where byte & 0xC0 != 0x80 {
				if byte == 0x0A {
					ranges.append(lineStart..<offset)
					starts.append(scalar + 1)
					lineStart = offset + 1
				}
				scalar += 1
			}
			ranges.append(lineStart..<buffer.count)
		}
		lineStarts = starts
		var headings: [Int: Int] = [:]
		var images: [Int: String] = [:]
		var links: [Int: [LineMarker]] = [:]
		var lists: [Int: Int64] = [:]
		var tableMarkers: [Int: LineMarker] = [:]
		for marker in session.getStructureMarkersFfi() {
			let line = line(forPosition: marker.position)
			switch marker.mtype {
			case .heading1: headings[line] = 1
			case .heading2: headings[line] = 2
			case .heading3: headings[line] = 3
			case .heading4: headings[line] = 4
			case .heading5: headings[line] = 5
			case .heading6: headings[line] = 6
			case .image: images[line] = marker.text
			case .link: links[line, default: []].append(marker)
			case .list: lists[line] = max(lists[line] ?? 0, marker.position + marker.length)
			case .table: tableMarkers[line] = marker
			default: break
			}
		}
		unitAtLine.reserveCapacity(ranges.count)
		// The end of the list being read, nested lists and all, or nil outside a list.
		var listEnd: Int64?
		for (line, range) in ranges.enumerated() {
			unitAtLine.append(units.count)
			if let end = listEnd, starts[line] >= end { listEnd = nil }
			let raw = String(decoding: bytes[range], as: UTF8.self)
			let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty else { continue }
			if let marker = tableMarkers[line], let table = TableParser.parse(marker.reference) {
				addTable(table, line: line)
				continue
			}
			if listEnd == nil, let end = lists[line] {
				listEnd = end
				listUnits.append(units.count)
				blocks.append(BookBlock(kind: .list, units: units.count..<units.count))
			}
			let kind: UnitKind
			if let level = headings[line] {
				kind = .heading(level: level)
			} else if let description = images[line] {
				// The engine names an image without a description "Image", which is no description at all.
				kind = .image(description: description.isEmpty || description == "Image" ? nil : description)
			} else if listEnd != nil {
				kind = .listItem
			} else {
				kind = .paragraph
			}
			let leading = raw.unicodeScalars.prefix { CharacterSet.whitespacesAndNewlines.contains($0) }.count
			let unitLinks = (links[line] ?? []).compactMap { Self.link($0, lineStart: starts[line], leading: leading, in: text) }
			add(BookUnit(kind: kind, line: line, text: Self.withoutTablePlaceholder(text, isTable: tableMarkers[line] != nil), links: unitLinks), joiningList: listEnd != nil)
		}
	}

	/// A table of one cell, or one whose HTML could not be read, is a paragraph of its text. The engine stands in for a
	/// table with "[Table]: " and its first row, and only the text counts.
	private static func withoutTablePlaceholder(_ text: String, isTable: Bool) -> String {
		guard isTable, let colon = text.range(of: "]: ") else { return text }
		let rest = text[colon.upperBound...].trimmingCharacters(in: .whitespaces)
		return rest.isEmpty ? text : rest
	}

	private func add(_ unit: BookUnit, joiningList: Bool = false) {
		let index = units.count
		if case .heading = unit.kind { headingUnits.append(index) }
		if case .image = unit.kind { imageUnits.append(index) }
		for link in unit.links.indices {
			linkStops.append((index, link))
		}
		units.append(unit)
		if joiningList, let last = blocks.indices.last, blocks[last].kind == .list {
			blocks[last].units = blocks[last].units.lowerBound..<index + 1
		} else {
			blocks.append(BookBlock(kind: .single, units: index..<index + 1))
		}
		blockOfUnit.append(blocks.count - 1)
	}

	/// A table is its caption, a block of its own, then a block of one unit per row.
	private func addTable(_ table: ParsedTable, line: Int) {
		if !table.caption.isEmpty {
			add(BookUnit(kind: .caption, line: line, text: table.caption, links: []))
		}
		let index = tables.count
		tables.append(table)
		let first = units.count
		tableUnits.append(first)
		blocks.append(BookBlock(kind: .table(index), units: first..<first + table.rowCount))
		for row in 0..<table.rowCount {
			let text = table.rows[row].map(\.text).joined(separator: " ")
			units.append(BookUnit(kind: .tableRow(table: index, row: row), line: line, text: text, links: []))
			blockOfUnit.append(blocks.count - 1)
		}
	}

	/// The first unit of the block after or before the one holding `unit`.
	func blockStart(from unit: Int, forward: Bool) -> Int? {
		guard blockOfUnit.indices.contains(unit) else { return nil }
		let block = blockOfUnit[unit] + (forward ? 1 : -1)
		return blocks.indices.contains(block) ? blocks[block].units.lowerBound : nil
	}

	/// Places a link marker in the unit's text. Its marker carries no length, so the link runs for its text.
	private static func link(_ marker: LineMarker, lineStart: Int64, leading: Int, in text: String) -> BookLink? {
		let scalars = text.unicodeScalars
		let offset = Int(marker.position - lineStart) - leading
		let length = marker.text.unicodeScalars.count
		guard offset >= 0, length > 0, offset < scalars.count else { return nil }
		let start = scalars.index(scalars.startIndex, offsetBy: offset)
		let end = scalars.index(start, offsetBy: min(length, scalars.count - offset))
		return BookLink(position: marker.position, text: marker.text, range: start..<end)
	}

	var count: Int { units.count }

	private func line(forPosition position: Int64) -> Int {
		var low = 0
		var high = lineStarts.count
		while low < high {
			let mid = (low + high) / 2
			if lineStarts[mid] <= position { low = mid + 1 } else { high = mid }
		}
		return max(low - 1, 0)
	}

	/// The unit holding a buffer position, or the last one before it when the position falls on a blank line.
	func unit(forPosition position: Int64) -> Int {
		guard !units.isEmpty else { return 0 }
		let line = line(forPosition: position)
		let after = unitAtLine.indices.contains(line) ? unitAtLine[line] : units.count
		if after < units.count, units[after].line == line { return after }
		return max(after - 1, 0)
	}

	/// Where a unit starts in the buffer, the position the engine saves and syncs.
	func position(ofUnit index: Int) -> Int64 {
		guard units.indices.contains(index) else { return 0 }
		return lineStarts[units[index].line]
	}

	/// The first stop after `index` going forward, or the last one before it going back.
	static func stop(in stops: [Int], from index: Int, forward: Bool) -> Int? {
		forward ? stops.first { $0 > index } : stops.last { $0 < index }
	}
}
