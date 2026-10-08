import Foundation

/// The open book's text as the reading screen's elements: one per paragraph, which in the engine's buffer is one line.
/// Blank lines are not elements, so a flick never lands on silence.
@MainActor
final class BookText {
	let session: DocumentSession
	private let lines: [Substring]
	/// The 0-based buffer line each element is.
	private let elementLines: [Int]
	private var headingLevels: [Int: Int] = [:]
	private var checkedHeadings = Set<Int>()

	init(session: DocumentSession) {
		self.session = session
		// The engine counts a line per "\n"; Swift reads "\r\n" as one character, so it has to count as a break too.
		let lines = session.content().split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
		self.lines = lines
		elementLines = lines.indices.filter { !lines[$0].allSatisfy(\.isWhitespace) }
	}

	var count: Int { elementLines.count }

	func text(at index: Int) -> String {
		guard elementLines.indices.contains(index) else { return "" }
		return lines[elementLines[index]].trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// The heading level of an element, or nil for a paragraph. Read from the engine's heading markers, which follow
	/// the table of contents.
	func headingLevel(at index: Int) -> Int? {
		guard elementLines.indices.contains(index) else { return nil }
		if checkedHeadings.contains(index) { return headingLevels[index] }
		checkedHeadings.insert(index)
		for marker in session.getLineMarkers(line: Int64(elementLines[index] + 1)) {
			let level: Int? = switch marker.mtype {
			case .heading1: 1
			case .heading2: 2
			case .heading3: 3
			case .heading4: 4
			case .heading5: 5
			case .heading6: 6
			default: nil
			}
			if let level {
				headingLevels[index] = level
				return level
			}
		}
		return nil
	}

	/// The element holding a buffer position, or the last one before it when the position falls on a blank line.
	func element(forPosition position: Int64) -> Int {
		guard count > 0 else { return 0 }
		let line = Int(session.lineFromPosition(position: position)) - 1
		var low = 0
		var high = elementLines.count
		while low < high {
			let mid = (low + high) / 2
			if elementLines[mid] <= line { low = mid + 1 } else { high = mid }
		}
		return max(low - 1, 0)
	}

	/// Where an element starts in the buffer, the position the engine saves and syncs.
	func position(ofElement index: Int) -> Int64 {
		guard elementLines.indices.contains(index) else { return 0 }
		return session.positionFromLine(line: Int64(elementLines[index] + 1))
	}
}
