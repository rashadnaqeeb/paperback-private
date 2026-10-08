import UIKit
import XCTest
@testable import Paperback

/// A book given as its buffer, answering line questions the way the engine does: a line per "\n", positions in
/// Unicode scalars, lines numbered from 1.
private final class TextSession: DocumentSession, @unchecked Sendable {
	var buffer = ""
	var headingLines: [Int64: MarkerType] = [:]

	private var lineStarts: [Int64] {
		var starts: [Int64] = [0]
		for (offset, scalar) in buffer.unicodeScalars.enumerated() where scalar == "\n" {
			starts.append(Int64(offset + 1))
		}
		return starts
	}

	override func content() -> String { buffer }
	override func lineCount() -> Int64 { Int64(lineStarts.count) }
	override func positionFromLine(line: Int64) -> Int64 {
		let starts = lineStarts
		return line <= 1 ? 0 : line <= Int64(starts.count) ? starts[Int(line) - 1] : Int64(buffer.unicodeScalars.count)
	}
	override func lineFromPosition(position: Int64) -> Int64 {
		Int64(lineStarts.filter { $0 <= position }.count)
	}
	override func getLineMarkers(line: Int64) -> [LineMarker] {
		guard let type = headingLines[line] else { return [] }
		return [LineMarker(mtype: type, position: positionFromLine(line: line), text: "", reference: "", level: 0, length: 0)]
	}
}

@MainActor
final class BookTextTests: XCTestCase {
	private func book(_ buffer: String) -> (TextSession, BookText) {
		let session = TextSession(noHandle: .init())
		session.buffer = buffer
		return (session, BookText(session: session))
	}

	func testEveryParagraphIsAnElementAndBlankLinesAreNot() {
		let (_, text) = book("Chapter One\nIt was a dark night.\n\n   \nThe end.")
		XCTAssertEqual(text.count, 3)
		XCTAssertEqual(text.text(at: 0), "Chapter One")
		XCTAssertEqual(text.text(at: 1), "It was a dark night.")
		XCTAssertEqual(text.text(at: 2), "The end.")
	}

	func testAWindowsLineBreakStillEndsTheParagraph() {
		let (_, text) = book("First\r\nSecond")
		XCTAssertEqual(text.count, 2)
		XCTAssertEqual(text.text(at: 0), "First")
	}

	func testAnElementMapsToItsLinesStartAndBack() {
		let (session, text) = book("One\n\nTwo\nThree")
		XCTAssertEqual(text.position(ofElement: 1), 5)
		XCTAssertEqual(text.element(forPosition: 5), 1)
		// A position partway into a paragraph is still that paragraph.
		XCTAssertEqual(text.element(forPosition: 7), 1)
		XCTAssertEqual(text.element(forPosition: session.positionFromLine(line: 4)), 2)
	}

	func testAPositionOnABlankLineBelongsToTheParagraphBefore() {
		let (_, text) = book("One\n\nTwo")
		XCTAssertEqual(text.element(forPosition: 4), 0)
	}

	func testPositionsCountUnicodeScalarsLikeTheEngine() {
		// The emoji is one scalar but two UTF-16 units, the difference between iOS and the Mac.
		let (_, text) = book("😀 smile\nNext")
		XCTAssertEqual(text.position(ofElement: 1), 8)
		XCTAssertEqual(text.element(forPosition: 8), 1)
	}

	func testHeadingsCarryTheirLevelFromTheEnginesMarkers() {
		let (session, text) = book("Part One\nChapter 1\nText.")
		session.headingLines = [1: .heading1, 2: .heading2]
		XCTAssertEqual(text.headingLevel(at: 0), 1)
		XCTAssertEqual(text.headingLevel(at: 1), 2)
		XCTAssertNil(text.headingLevel(at: 2))
	}
}

@MainActor
final class BookViewTests: XCTestCase {
	private func view(paragraphs: Int) -> BookView {
		let session = TextSession(noHandle: .init())
		session.buffer = (0..<paragraphs).map { "Paragraph \($0) of a book that goes on long enough to wrap onto a second line." }.joined(separator: "\n")
		let view = BookView(text: BookText(session: session))
		view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
		view.layoutIfNeeded()
		return view
	}

	func testTheWholeBookIsReportedButElementsAreMadeOnlyWhenAsked() {
		let view = view(paragraphs: 20_000)
		XCTAssertEqual(view.accessibilityElementCount(), 20_000)
		let element = view.accessibilityElement(at: 12_345) as? ParagraphElement
		XCTAssertEqual(element?.index, 12_345)
		XCTAssertEqual(view.index(ofAccessibilityElement: element as Any), 12_345)
	}

	func testParagraphsOnThePageAreOnScreenAndNoOthers() {
		let view = view(paragraphs: 200)
		view.reveal(50)
		XCTAssertEqual(view.firstIndexOnPage, 50)
		XCTAssertGreaterThan(view.lastIndexOnPage, 50)
		for index in 40..<80 {
			let frame = view.frame(forElement: index)
			let onPage = index >= view.firstIndexOnPage && index <= view.lastIndexOnPage
			XCTAssertEqual(view.bounds.intersects(frame), onPage, "paragraph \(index)")
		}
	}

	func testPageParagraphsDoNotOverlap() {
		let view = view(paragraphs: 200)
		view.reveal(0)
		for index in view.firstIndexOnPage..<view.lastIndexOnPage {
			XCTAssertLessThanOrEqual(view.frame(forElement: index).maxY, view.frame(forElement: index + 1).minY)
		}
	}

	func testFocusLeavingThePageTurnsItForwardAndBack() {
		let view = view(paragraphs: 200)
		view.reveal(10)
		let next = view.lastIndexOnPage + 1
		view.elementBecameFocused(next)
		XCTAssertEqual(view.firstIndexOnPage, next)
		view.elementBecameFocused(next - 1)
		// Turning back ends the new page on the paragraph focus went to.
		XCTAssertEqual(view.lastIndexOnPage, next - 1)
	}

	func testFocusWithinThePageLeavesItAlone() {
		let view = view(paragraphs: 200)
		view.reveal(50)
		let first = view.firstIndexOnPage
		view.elementBecameFocused(view.lastIndexOnPage)
		XCTAssertEqual(view.firstIndexOnPage, first)
	}

	func testSwipingTurnsWholePages() {
		let view = view(paragraphs: 200)
		view.reveal(0)
		let last = view.lastIndexOnPage
		view.turnPage(forward: true)
		XCTAssertEqual(view.firstIndexOnPage, last + 1)
		view.turnPage(forward: false)
		XCTAssertEqual(view.lastIndexOnPage, last)
	}

	func testAParagraphTallerThanTheScreenStillGetsAPage() {
		let session = TextSession(noHandle: .init())
		session.buffer = "Short.\n" + String(repeating: "A very long paragraph indeed. ", count: 400) + "\nAfter."
		let view = BookView(text: BookText(session: session))
		view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
		view.layoutIfNeeded()
		view.elementBecameFocused(1)
		XCTAssertEqual(view.firstIndexOnPage, 1)
		XCTAssertEqual(view.lastIndexOnPage, 1)
		XCTAssertGreaterThan(view.frame(forElement: 1).height, view.bounds.height)
	}
}
