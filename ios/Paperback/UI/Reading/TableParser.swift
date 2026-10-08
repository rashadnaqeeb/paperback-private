import Foundation

/// A table rebuilt from the HTML the engine keeps on its table marker, as a grid of cells.
struct ParsedTable: Equatable {
	struct Cell: Equatable {
		var text: String
		var isHeader: Bool
		var row: Int
		var column: Int
		var rowSpan: Int
		var columnSpan: Int
	}

	var caption: String
	/// The cells starting in each row, left to right.
	var rows: [[Cell]]
	var columnCount: Int
	/// How many leading rows are header rows, whose cells name the columns below them.
	var headerRowCount: Int

	var rowCount: Int { rows.count }

	/// The cell covering a grid position, wherever its spans start it.
	func cell(row: Int, column: Int) -> Cell? {
		for candidates in rows.prefix(row + 1) {
			if let cell = candidates.first(where: { $0.row <= row && row < $0.row + $0.rowSpan && $0.column <= column && column < $0.column + $0.columnSpan }) {
				return cell
			}
		}
		return nil
	}

	/// The header cells naming a column.
	func columnHeaders(_ column: Int) -> [Cell] {
		(0..<headerRowCount).compactMap { cell(row: $0, column: column) }.filter(\.isHeader)
	}

	/// The header cell naming a row, when the row starts with one.
	func rowHeaders(_ row: Int) -> [Cell] {
		guard row >= headerRowCount, let first = cell(row: row, column: 0), first.isHeader else { return [] }
		return [first]
	}
}

/// Reads an HTML table into a grid: captions, header cells from `th` or `thead`, row and column spans. Anything
/// inside a cell that is not text (images, links, nested markup, nested tables) contributes only its text.
enum TableParser {
	static func parse(_ html: String) -> ParsedTable? {
		var caption = ""
		var rows: [[(text: String, isHeader: Bool, rowSpan: Int, columnSpan: Int)]] = []
		var row: [(text: String, isHeader: Bool, rowSpan: Int, columnSpan: Int)]?
		var cell: (text: String, isHeader: Bool, rowSpan: Int, columnSpan: Int)?
		var inCaption = false
		var inHead = false
		var depth = 0
		var skipping: String?
		func finishCell() {
			guard var done = cell else { return }
			done.text = collapse(done.text)
			if row == nil { row = [] }
			row?.append(done)
			cell = nil
		}
		func finishRow() {
			finishCell()
			if let done = row, !done.isEmpty { rows.append(done) }
			row = nil
		}
		func appendText(_ text: String) {
			if inCaption {
				caption += text
			} else if cell != nil {
				cell?.text += text
			}
		}
		var rest = html[...]
		while !rest.isEmpty {
			guard let open = rest.firstIndex(of: "<") else {
				if skipping == nil { appendText(decodeEntities(String(rest))) }
				break
			}
			if skipping == nil, open > rest.startIndex { appendText(decodeEntities(String(rest[..<open]))) }
			guard let close = rest[open...].firstIndex(of: ">") else { break }
			let tag = rest[rest.index(after: open)..<close]
			rest = rest[rest.index(after: close)...]
			let isClosing = tag.hasPrefix("/")
			let name = tag.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
			if let skipped = skipping {
				if isClosing, name == skipped { skipping = nil }
				continue
			}
			switch (name, isClosing) {
			case ("script", false), ("style", false):
				skipping = name
			case ("table", false):
				depth += 1
			case ("table", true):
				depth -= 1
				if depth == 0 { finishRow() }
			case _ where depth > 1:
				// A table inside a cell is only its text.
				appendText(" ")
			case ("caption", false):
				inCaption = true
			case ("caption", true):
				inCaption = false
			case ("thead", false):
				inHead = true
			case ("thead", true), ("tbody", false), ("tfoot", false):
				inHead = false
			case ("tr", false):
				finishRow()
				row = []
			case ("tr", true):
				finishRow()
			case ("td", false), ("th", false):
				finishCell()
				cell = (
					"",
					name == "th" || inHead,
					// Bounded as browsers bound them, and tighter across: a stray colspan="1000" would otherwise squeeze every
					// column to nothing.
					min(max(attribute("rowspan", in: tag) ?? 1, 1), 65534),
					min(max(attribute("colspan", in: tag) ?? 1, 1), 50)
				)
			case ("td", true), ("th", true):
				finishCell()
			case ("br", _), ("p", _), ("div", _), ("li", _):
				appendText(" ")
			default:
				break
			}
		}
		finishRow()
		// Lay the cells out on a grid, each one starting in the first column its row has free.
		var occupied: [[Bool]] = []
		var placed: [[ParsedTable.Cell]] = []
		var columnCount = 0
		for (r, cells) in rows.enumerated() {
			var column = 0
			var placedRow: [ParsedTable.Cell] = []
			for var cell in cells {
				// A span cannot reach past the last row, and filling rows that do not exist would only cost memory.
				cell.rowSpan = min(cell.rowSpan, rows.count - r)
				while occupied.count > r, column < occupied[r].count, occupied[r][column] { column += 1 }
				for dr in 0..<cell.rowSpan {
					let target = r + dr
					while occupied.count <= target { occupied.append([]) }
					while occupied[target].count < column + cell.columnSpan { occupied[target].append(false) }
					for dc in 0..<cell.columnSpan { occupied[target][column + dc] = true }
				}
				placedRow.append(ParsedTable.Cell(text: cell.text, isHeader: cell.isHeader, row: r, column: column, rowSpan: cell.rowSpan, columnSpan: cell.columnSpan))
				column += cell.columnSpan
				columnCount = max(columnCount, column)
			}
			placed.append(placedRow)
		}
		guard placed.reduce(0, { $0 + $1.count }) > 1 else { return nil }
		// A header row may start with an empty corner cell, marked up as a plain td.
		var headerRowCount = placed.prefix { cells in cells.contains(where: \.isHeader) && cells.allSatisfy { $0.isHeader || $0.text.isEmpty } }.count
		let anyHeader = placed.contains { $0.contains(where: \.isHeader) }
		if headerRowCount == 0, !anyHeader, placed.count > 1 {
			// With no header cells marked at all, the first row names the columns, as in most books.
			headerRowCount = 1
			placed[0] = placed[0].map { cell in
				var header = cell
				header.isHeader = true
				return header
			}
		}
		return ParsedTable(caption: collapse(caption), rows: placed, columnCount: max(columnCount, 1), headerRowCount: min(headerRowCount, placed.count - 1))
	}

	/// A whole-number attribute of a tag, which HTML lets have spaces around its "=".
	private static func attribute(_ name: String, in tag: Substring) -> Int? {
		var rest = tag[...]
		while let range = rest.range(of: name, options: .caseInsensitive) {
			rest = rest[range.upperBound...]
			// The name has to be whole: not the end of data-colspan, nor the start of colspanned.
			guard range.lowerBound > tag.startIndex, tag[tag.index(before: range.lowerBound)].isWhitespace else { continue }
			let afterName = rest.drop { $0.isWhitespace }
			guard afterName.first == "=" else { continue }
			let value = afterName.dropFirst().drop { $0.isWhitespace || $0 == "\"" || $0 == "'" }.prefix { $0.isNumber }
			return Int(value)
		}
		return nil
	}

	private static func collapse(_ text: String) -> String {
		text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	private static let namedEntities: [String: String] = [
		"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
		"lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "hellip": "…", "deg": "°", "times": "×",
	]

	static func decodeEntities(_ text: String) -> String {
		guard text.contains("&") else { return text }
		var result = ""
		var rest = text[...]
		while let amp = rest.firstIndex(of: "&") {
			result += rest[..<amp]
			let afterAmp = rest.index(after: amp)
			guard let semicolon = rest[afterAmp...].prefix(10).firstIndex(of: ";") else {
				result += "&"
				rest = rest[afterAmp...]
				continue
			}
			let entity = rest[afterAmp..<semicolon]
			var decoded: String?
			if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
				decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
			} else if entity.hasPrefix("#") {
				decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
			} else {
				decoded = namedEntities[String(entity)]
			}
			if let decoded {
				result += decoded
				rest = rest[rest.index(after: semicolon)...]
			} else {
				result += "&"
				rest = rest[afterAmp...]
			}
		}
		return result + rest
	}
}
