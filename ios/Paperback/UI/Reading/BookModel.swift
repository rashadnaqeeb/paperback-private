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
	/// Where in its line the unit stands, in the engine's positions. Only a table's rows share a line, and each takes
	/// its own offset so the reading position, bookmarks, and sync can tell them apart.
	var offset = 0
	/// A paragraph holding an image among its text, which the Images rotor stops on.
	var hasInlineImage = false

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
	/// The book's own pages: where each starts, in buffer order, and its printed number.
	private(set) var pagePositions: [Int64] = []
	private(set) var pageLabels: [String] = []
	/// Every link in reading order, as its unit and its index among that unit's links.
	private(set) var linkStops: [(unit: Int, link: Int)] = []
	/// Set when a list starts and cleared when its first item makes its block, so a list right after another one does
	/// not run into it.
	private var listStarting = false

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
		var images: [Int: LineMarker] = [:]
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
			case .image: images[line] = marker
			case .link: links[line, default: []].append(marker)
			case .list: lists[line] = max(lists[line] ?? 0, marker.position + marker.length)
			case .table: tableMarkers[line] = marker
			case .pageBreak:
				pagePositions.append(marker.position)
				pageLabels.append(marker.text)
			default: break
			}
		}
		unitAtLine.reserveCapacity(ranges.count)
		// The end of the list being read, nested lists and all, or nil outside a list.
		var listEnd: Int64?
		for (line, range) in ranges.enumerated() {
			unitAtLine.append(units.count)
			if let end = listEnd, starts[line] >= end {
				listEnd = nil
				listStarting = false
			}
			let raw = String(decoding: bytes[range], as: UTF8.self)
			let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty else { continue }
			if listEnd == nil, let end = lists[line] {
				listEnd = end
				listStarting = true
			}
			let leading = raw.unicodeScalars.prefix { CharacterSet.whitespacesAndNewlines.contains($0) }.count
			let length = text.unicodeScalars.count
			if let marker = tableMarkers[line], let table = TableParser.parse(marker.reference) {
				addTable(table, line: line, offset: leading, length: length)
				continue
			}
			// The engine writes an image into the text where it stands; only a line that is nothing but the image is one.
			let image = images[line].flatMap { $0.position == starts[line] + Int64(leading) && $0.length >= length ? $0 : nil }
			let kind: UnitKind
			if let level = headings[line] {
				kind = .heading(level: level)
			} else if let image {
				// The engine names an image without a description "Image", which is no description at all.
				kind = .image(description: image.text.isEmpty || image.text == "Image" ? nil : image.text)
			} else if listEnd != nil {
				kind = .listItem
			} else {
				kind = .paragraph
			}
			let unitLinks = (links[line] ?? []).compactMap { Self.link($0, lineStart: starts[line], leading: leading, in: text) }
			var unit = BookUnit(kind: kind, line: line, text: Self.withoutTablePlaceholder(text, isTable: tableMarkers[line] != nil), links: unitLinks)
			unit.hasInlineImage = image == nil && images[line] != nil
			add(unit, joiningList: listEnd != nil)
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
		if case .image = unit.kind { imageUnits.append(index) } else if unit.hasInlineImage { imageUnits.append(index) }
		for link in unit.links.indices {
			linkStops.append((index, link))
		}
		units.append(unit)
		if joiningList, !listStarting, let last = blocks.indices.last, blocks[last].kind == .list {
			blocks[last].units = blocks[last].units.lowerBound..<index + 1
		} else if joiningList {
			// A new list, or, after a table inside a list, the items that carry on in a container of their own.
			if listStarting { listUnits.append(index) }
			listStarting = false
			blocks.append(BookBlock(kind: .list, units: index..<index + 1))
		} else {
			blocks.append(BookBlock(kind: .single, units: index..<index + 1))
		}
		blockOfUnit.append(blocks.count - 1)
	}

	/// A table is its caption, a block of its own, then a block of one unit per row. The table is one line of the
	/// buffer, its placeholder text, so each row stands at its own offset into that line, the last ones sharing its
	/// last position when the table has more rows than the placeholder has characters.
	private func addTable(_ table: ParsedTable, line: Int, offset: Int, length: Int) {
		var next = 0
		if !table.caption.isEmpty {
			var caption = BookUnit(kind: .caption, line: line, text: table.caption, links: [])
			caption.offset = offset
			add(caption)
			next = 1
		}
		let index = tables.count
		tables.append(table)
		let first = units.count
		tableUnits.append(first)
		blocks.append(BookBlock(kind: .table(index), units: first..<first + table.rowCount))
		for row in 0..<table.rowCount {
			var unit = BookUnit(kind: .tableRow(table: index, row: row), line: line, text: table.rows[row].map(\.text).joined(separator: " "), links: [])
			unit.offset = offset + min(next + row, max(length - 1, 0))
			units.append(unit)
			blockOfUnit.append(blocks.count - 1)
		}
	}

	/// The book's page holding a position, as its index into the page lists.
	func page(atPosition position: Int64) -> Int? {
		pagePositions.lastIndex { $0 <= position }
	}

	/// Where a page turn lands: the next or previous page and the unit holding its start. A printed page often starts
	/// inside a paragraph, so the pages are counted, not the units: `known` is the page the reader last turned to while
	/// still on that unit, and otherwise the unit's own span decides.
	func pageTurn(from unit: Int, onPage known: Int?, forward: Bool) -> (unit: Int, page: Int)? {
		guard units.indices.contains(unit), !pagePositions.isEmpty else { return nil }
		let target: Int
		if forward {
			// Past every page that starts inside the unit, or the reader would turn to one they are already reading.
			target = (known ?? page(atPosition: lastPosition(ofUnit: unit)) ?? -1) + 1
		} else if let known {
			target = known - 1
		} else if let start = page(atPosition: position(ofUnit: unit)) {
			target = self.unit(forPosition: pagePositions[start]) == unit ? start - 1 : start
		} else {
			return nil
		}
		guard pagePositions.indices.contains(target) else { return nil }
		return (self.unit(forPosition: pagePositions[target]), target)
	}

	/// The last position in a unit's line.
	private func lastPosition(ofUnit index: Int) -> Int64 {
		let line = units[index].line
		return line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : Int64.max
	}

	/// How a page is spoken: its printed number as "Page 812", or the engine's own name for it ("Page 3" in a PDF,
	/// "Slide 3" in a presentation) as it is.
	static func pageName(_ label: String) -> String {
		// TRANSLATORS: A printed page of a book; {} is the number as printed, which may be a roman numeral
		label.contains(" ") ? label : t("Page {}").replacingOccurrences(of: "{}", with: label)
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

	/// The unit holding a buffer position, or the last one before it when the position falls on a blank line. On a
	/// table's line, the row standing at or before the position.
	func unit(forPosition position: Int64) -> Int {
		guard !units.isEmpty else { return 0 }
		let line = line(forPosition: position)
		let after = unitAtLine.indices.contains(line) ? unitAtLine[line] : units.count
		guard after < units.count, units[after].line == line else { return max(after - 1, 0) }
		var unit = after
		while unit + 1 < units.count, units[unit + 1].line == line, self.position(ofUnit: unit + 1) <= position {
			unit += 1
		}
		return unit
	}

	/// Where a unit starts in the buffer, the position the engine saves and syncs.
	func position(ofUnit index: Int) -> Int64 {
		guard units.indices.contains(index) else { return 0 }
		return lineStarts[units[index].line] + Int64(units[index].offset)
	}

	/// The first stop after `index` going forward, or the last one before it going back.
	static func stop(in stops: [Int], from index: Int, forward: Bool) -> Int? {
		forward ? stops.first { $0 > index } : stops.last { $0 < index }
	}
}
