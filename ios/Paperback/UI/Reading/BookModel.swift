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
}

/// One thing the reading screen lays out and VoiceOver stops on: a paragraph, heading, or image, which in the
/// engine's buffer is one non-blank line.
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

/// The open book as the reading screen sees it: its units in reading order, and the maps the rotors move by.
/// Built once when the book opens, from the buffer and one pass over the engine's markers.
@MainActor
final class BookModel {
	let session: DocumentSession
	private(set) var units: [BookUnit] = []
	/// Where each buffer line starts, in the engine's positions (Unicode scalars on iOS).
	private let lineStarts: [Int64]
	/// The first unit on or after each buffer line, for mapping positions to units.
	private var unitAtLine: [Int] = []
	private(set) var headingUnits: [Int] = []
	private(set) var imageUnits: [Int] = []
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
			default: break
			}
		}
		unitAtLine.reserveCapacity(ranges.count)
		for (line, range) in ranges.enumerated() {
			unitAtLine.append(units.count)
			let raw = String(decoding: bytes[range], as: UTF8.self)
			let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty else { continue }
			let kind: UnitKind
			if let level = headings[line] {
				kind = .heading(level: level)
			} else if let description = images[line] {
				// The engine names an image without a description "Image", which is no description at all.
				kind = .image(description: description.isEmpty || description == "Image" ? nil : description)
			} else {
				kind = .paragraph
			}
			let leading = raw.unicodeScalars.prefix { CharacterSet.whitespacesAndNewlines.contains($0) }.count
			let unitLinks = (links[line] ?? []).compactMap { Self.link($0, lineStart: starts[line], leading: leading, in: text) }
			add(BookUnit(kind: kind, line: line, text: text, links: unitLinks))
		}
	}

	private func add(_ unit: BookUnit) {
		let index = units.count
		if case .heading = unit.kind { headingUnits.append(index) }
		if case .image = unit.kind { imageUnits.append(index) }
		for link in unit.links.indices {
			linkStops.append((index, link))
		}
		units.append(unit)
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
