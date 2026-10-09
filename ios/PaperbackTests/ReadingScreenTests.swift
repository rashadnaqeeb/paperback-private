import UIKit
import XCTest
@testable import Paperback

/// A book given as its buffer, answering line questions the way the engine does: a line per "\n", positions in
/// Unicode scalars, lines numbered from 1.
private final class TextSession: DocumentSession, @unchecked Sendable {
	var buffer = ""
	var markers: [LineMarker] = []
	var toc: [TocEntry] = []

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
	override func getStructureMarkersFfi() -> [LineMarker] { markers }
	override func getToc() -> [TocEntry] { toc }

	func mark(_ type: MarkerType, at position: Int64, text: String = "") {
		markers.append(LineMarker(mtype: type, position: position, text: text, reference: "", level: 0, length: 0))
	}
}

@MainActor
final class BookModelTests: XCTestCase {
	private func book(_ buffer: String, marks: (TextSession) -> Void = { _ in }) -> (TextSession, BookModel) {
		let session = TextSession(noHandle: .init())
		session.buffer = buffer
		marks(session)
		return (session, BookModel(session: session))
	}

	func testEveryParagraphIsAnElementAndBlankLinesAreNot() {
		let (_, text) = book("Chapter One\nIt was a dark night.\n\n   \nThe end.")
		XCTAssertEqual(text.count, 3)
		XCTAssertEqual(text.units[0].text, "Chapter One")
		XCTAssertEqual(text.units[1].text, "It was a dark night.")
		XCTAssertEqual(text.units[2].text, "The end.")
	}

	func testAWindowsLineBreakStillEndsTheParagraph() {
		let (_, text) = book("First\r\nSecond")
		XCTAssertEqual(text.count, 2)
		XCTAssertEqual(text.units[0].text, "First")
	}

	func testAnElementMapsToItsLinesStartAndBack() {
		let (session, text) = book("One\n\nTwo\nThree")
		XCTAssertEqual(text.position(ofUnit: 1), 5)
		XCTAssertEqual(text.unit(forPosition: 5), 1)
		// A position partway into a paragraph is still that paragraph.
		XCTAssertEqual(text.unit(forPosition: 7), 1)
		XCTAssertEqual(text.unit(forPosition: session.positionFromLine(line: 4)), 2)
	}

	func testAPositionOnABlankLineBelongsToTheParagraphBefore() {
		let (_, text) = book("One\n\nTwo")
		XCTAssertEqual(text.unit(forPosition: 4), 0)
	}

	func testPositionsCountUnicodeScalarsLikeTheEngine() {
		// The emoji is one scalar but two UTF-16 units, the difference between iOS and the Mac.
		let (_, text) = book("😀 smile\nNext")
		XCTAssertEqual(text.position(ofUnit: 1), 8)
		XCTAssertEqual(text.unit(forPosition: 8), 1)
	}

	func testHeadingsCarryTheirLevelFromTheEnginesMarkers() {
		let (_, text) = book("Part One\nChapter 1\nText.") {
			$0.mark(.heading1, at: 0)
			$0.mark(.heading2, at: 9)
		}
		XCTAssertEqual(text.units[0].kind, .heading(level: 1))
		XCTAssertEqual(text.units[1].kind, .heading(level: 2))
		XCTAssertEqual(text.units[2].kind, .paragraph)
		XCTAssertEqual(text.headingUnits, [0, 1])
	}

	func testAnImageInsideAParagraphLeavesItAParagraph() {
		let (_, text) = book("[Image: T]he night was dark.") {
			$0.markers.append(LineMarker(mtype: .image, position: 0, text: "T", reference: "", level: 0, length: 10))
		}
		XCTAssertEqual(text.units[0].kind, .paragraph)
		XCTAssertEqual(text.units[0].text, "[Image: T]he night was dark.")
		XCTAssertEqual(text.imageUnits, [0])
	}

	func testAnImageSpeaksItsDescriptionOrNothingWhenItHasNone() {
		let (_, text) = book("[Image: A map]\n[Image: Image]\nText.") {
			$0.markers.append(LineMarker(mtype: .image, position: 0, text: "A map", reference: "", level: 0, length: 14))
			$0.markers.append(LineMarker(mtype: .image, position: 15, text: "Image", reference: "", level: 0, length: 14))
		}
		XCTAssertEqual(text.units[0].kind, .image(description: "A map"))
		XCTAssertEqual(text.units[1].kind, .image(description: nil))
		XCTAssertEqual(text.imageUnits, [0, 1])
	}

	func testLinksSitInsideTheirParagraphAtTheirText() {
		let (_, text) = book("Intro\n  See note 1 and note 2.") {
			$0.mark(.link, at: 12, text: "note 1")
			$0.mark(.link, at: 23, text: "note 2")
		}
		let unit = text.units[1]
		XCTAssertEqual(unit.links.count, 2)
		XCTAssertEqual(String(unit.text[unit.links[0].range]), "note 1")
		XCTAssertEqual(String(unit.text[unit.links[1].range]), "note 2")
		XCTAssertFalse(unit.isWholeLink)
		XCTAssertEqual(text.linkStops.map(\.unit), [1, 1])
		XCTAssertEqual(text.linkStops.map(\.link), [0, 1])
	}

	func testAParagraphThatIsOneLinkIsAWholeLink() {
		let (_, text) = book("Chapter 3") { $0.mark(.link, at: 0, text: "Chapter 3") }
		XCTAssertTrue(text.units[0].isWholeLink)
	}

	func testRotorStopsStepStrictlyPastTheOrigin() {
		XCTAssertEqual(BookModel.stop(in: [2, 5, 9], from: 5, forward: true), 9)
		XCTAssertEqual(BookModel.stop(in: [2, 5, 9], from: 5, forward: false), 2)
		XCTAssertNil(BookModel.stop(in: [2, 5, 9], from: 9, forward: true))
		XCTAssertNil(BookModel.stop(in: [2, 5, 9], from: 2, forward: false))
	}
}

@MainActor
final class BookViewTests: XCTestCase {
	private func view(paragraphs: Int) -> BookView {
		let session = TextSession(noHandle: .init())
		session.buffer = (0..<paragraphs).map { "Paragraph \($0) of a book that goes on long enough to wrap onto a second line." }.joined(separator: "\n")
		let view = BookView(model: BookModel(session: session))
		view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
		view.layoutIfNeeded()
		return view
	}

	func testTheWholeBookIsReportedButElementsAreMadeOnlyWhenAsked() {
		let view = view(paragraphs: 20_000)
		XCTAssertEqual(view.accessibilityElementCount(), 20_000)
		let element = view.accessibilityElement(at: 12_345) as? ParagraphElement
		XCTAssertEqual(element?.unit, 12_345)
		XCTAssertEqual(view.index(ofAccessibilityElement: element as Any), 12_345)
	}

	func testParagraphsOnThePageAreOnScreenAndNoOthers() {
		let view = view(paragraphs: 200)
		view.reveal(50)
		XCTAssertEqual(view.firstUnitOnPage, 50)
		XCTAssertGreaterThan(view.lastUnitOnPage, 50)
		for index in 40..<80 {
			let frame = view.frame(forUnit: index)
			let onPage = index >= view.firstUnitOnPage && index <= view.lastUnitOnPage
			XCTAssertEqual(view.bounds.intersects(frame), onPage, "paragraph \(index)")
		}
	}

	func testPageParagraphsDoNotOverlap() {
		let view = view(paragraphs: 200)
		view.reveal(0)
		for index in view.firstUnitOnPage..<view.lastUnitOnPage {
			XCTAssertLessThanOrEqual(view.frame(forUnit: index).maxY, view.frame(forUnit: index + 1).minY)
		}
	}

	func testFocusLeavingThePageTurnsItForwardAndBack() {
		let view = view(paragraphs: 200)
		view.reveal(10)
		let next = view.lastUnitOnPage + 1
		view.unitBecameFocused(next)
		XCTAssertEqual(view.firstUnitOnPage, next)
		view.unitBecameFocused(next - 1)
		// Turning back ends the new page on the paragraph focus went to.
		XCTAssertEqual(view.lastUnitOnPage, next - 1)
	}

	func testFocusWithinThePageLeavesItAlone() {
		let view = view(paragraphs: 200)
		view.reveal(50)
		let first = view.firstUnitOnPage
		view.unitBecameFocused(view.lastUnitOnPage)
		XCTAssertEqual(view.firstUnitOnPage, first)
	}

	func testSwipingTurnsWholePages() {
		let view = view(paragraphs: 200)
		view.reveal(0)
		let last = view.lastUnitOnPage
		view.turnPage(forward: true)
		XCTAssertEqual(view.firstUnitOnPage, last + 1)
		view.turnPage(forward: false)
		XCTAssertEqual(view.lastUnitOnPage, last)
	}

	func testAParagraphTallerThanTheScreenStillGetsAPage() {
		let session = TextSession(noHandle: .init())
		session.buffer = "Short.\n" + String(repeating: "A very long paragraph indeed. ", count: 400) + "\nAfter."
		let view = BookView(model: BookModel(session: session))
		view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
		view.layoutIfNeeded()
		view.unitBecameFocused(1)
		XCTAssertEqual(view.firstUnitOnPage, 1)
		XCTAssertEqual(view.lastUnitOnPage, 1)
		XCTAssertGreaterThan(view.frame(forUnit: 1).height, view.bounds.height)
	}

	private func structuredView(contents: Bool = false) -> BookView {
		let session = TextSession(noHandle: .init())
		// Lines start at 0, 10, 39, 49, 62.
		session.buffer = "Chapter 1\nText with note 1 and note 2.\nChapter 2\n[Image: Map]\nMore text here."
		session.mark(.heading1, at: 0)
		session.mark(.link, at: 20, text: "note 1")
		session.mark(.link, at: 31, text: "note 2")
		session.mark(.heading1, at: 39)
		session.markers.append(LineMarker(mtype: .image, position: 49, text: "Map", reference: "", level: 0, length: 12))
		if contents {
			session.toc = [TocEntry(title: "Chapter 1", position: 0, level: 1), TocEntry(title: "Chapter 2", position: 39, level: 1)]
		}
		let view = BookView(model: BookModel(session: session))
		view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
		view.layoutIfNeeded()
		return view
	}

	private func rotor(_ view: BookView, _ type: UIAccessibilityCustomRotor.SystemRotorType) -> UIAccessibilityCustomRotor? {
		view.accessibilityCustomRotors?.first { $0.systemRotorType == type }
	}

	private func search(_ rotor: UIAccessibilityCustomRotor?, from element: Any?, forward: Bool = true) -> Any? {
		let predicate = UIAccessibilityCustomRotorSearchPredicate()
		predicate.searchDirection = forward ? .next : .previous
		predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: element as? NSObjectProtocol ?? NSObject(), targetRange: nil)
		return rotor?.itemSearchBlock(predicate)?.targetElement
	}

	func testTheHeadingsRotorMovesBetweenHeadingsAndRecordsTheJump() {
		let view = structuredView()
		var jumpedFrom: [Int] = []
		view.onRotorJump = { jumpedFrom.append($0) }
		let first = view.element(forUnit: 0)
		let next = search(rotor(view, .heading), from: first) as? ParagraphElement
		XCTAssertEqual(next?.unit, 2)
		XCTAssertEqual(jumpedFrom, [0])
		XCTAssertNil(search(rotor(view, .heading), from: next))
	}

	func testTheLinksRotorStepsThroughEachLinkInsideItsParagraph() {
		let view = structuredView()
		let links = rotor(view, .link)
		let first = search(links, from: view.element(forUnit: 0)) as? LinkElement
		XCTAssertEqual(first?.unit, 1)
		XCTAssertEqual(first?.link, 0)
		XCTAssertEqual(first?.accessibilityLabel, "note 1")
		XCTAssertTrue(first?.accessibilityTraits.contains(.link) ?? false)
		let second = search(links, from: first) as? LinkElement
		XCTAssertEqual(second?.link, 1)
		let back = search(links, from: second, forward: false) as? LinkElement
		XCTAssertEqual(back?.link, 0)
		XCTAssertNil(search(links, from: second))
	}

	/// Every rotor move counts as a jump for the temporary bookmark, but stepping between links of one paragraph does not
	/// leave the place being read.
	func testTheLinksRotorReportsAJumpOnlyWhenItLeavesTheParagraph() {
		let view = structuredView()
		var jumpedFrom: [Int] = []
		view.onRotorJump = { jumpedFrom.append($0) }
		let links = rotor(view, .link)
		let first = search(links, from: view.element(forUnit: 0))
		_ = search(links, from: first)
		XCTAssertEqual(jumpedFrom, [0])
	}

	func testALinkSitsAtItsParagraphsPlaceSoAFlickMovesOn() {
		let view = structuredView()
		let link = view.element(forLink: 1, inUnit: 1)
		XCTAssertEqual(view.index(ofAccessibilityElement: link as Any), 1)
	}

	func testTheScrubLeavesTheBook() {
		let view = structuredView()
		var left = false
		view.onEscape = { left = true }
		XCTAssertTrue(view.accessibilityPerformEscape())
		XCTAssertTrue(left)
	}

	func testAListItemKeepsItsListWhenTheViewLetsTheListGo() {
		let session = TextSession(noHandle: .init())
		session.buffer = (["• First", "• Second"] + (0..<2000).map { "Paragraph \($0)" }).joined(separator: "\n")
		session.markers.append(LineMarker(mtype: .list, position: 0, text: "", reference: "", level: 2, length: 16))
		let view = BookView(model: BookModel(session: session))
		view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
		view.layoutIfNeeded()
		let item = view.element(forUnit: 1)
		view.unitBecameFocused(1500)
		for unit in 1400..<1700 { _ = view.element(forUnit: unit) }
		XCTAssertTrue(item?.accessibilityContainer is ListElement)
	}

	func testThereIsNoImagesRotorButAnImageStillSpeaksItsDescription() {
		let view = structuredView()
		XCTAssertNil(rotor(view, .image))
		XCTAssertEqual((view.element(forUnit: 3) as? ParagraphElement)?.accessibilityLabel, "Map")
	}

	func testOnlyTheRotorsTheBookHasSomethingForAreOffered() {
		let rotors = structuredView().accessibilityCustomRotors ?? []
		XCTAssertEqual(rotors.map(\.systemRotorType), [.heading, .link])
		XCTAssertEqual(view(paragraphs: 5).accessibilityCustomRotors?.count, 0)
	}

	func testTheSectionsRotorMovesBetweenContentsEntriesAndRecordsTheJump() {
		let view = structuredView(contents: true)
		var jumpedFrom: [Int] = []
		view.onRotorJump = { jumpedFrom.append($0) }
		let sections = view.accessibilityCustomRotors?.first { $0.name == t("Sections") }
		XCTAssertEqual((search(sections, from: view.element(forUnit: 0)) as? ParagraphElement)?.unit, 2)
		XCTAssertEqual(jumpedFrom, [0])
		XCTAssertNil(search(sections, from: view.element(forUnit: 2)))
		XCTAssertEqual((search(sections, from: view.element(forUnit: 3), forward: false) as? ParagraphElement)?.unit, 2)
	}

	func testTheBookmarksRotorAppearsOnceThereIsABookmark() {
		let view = view(paragraphs: 5)
		var positions: [Int64] = []
		view.bookmarkPositions = { positions }
		XCTAssertFalse(view.accessibilityCustomRotors?.contains { $0.name == t("Bookmarks") } ?? true)
		positions = [0]
		XCTAssertTrue(view.accessibilityCustomRotors?.contains { $0.name == t("Bookmarks") } ?? false)
	}

	func testFollowingALinkAsksTheBookView() {
		let view = structuredView()
		var followed: (Int, Int)?
		view.onFollowLink = { followed = ($0, $1) }
		_ = view.element(forLink: 1, inUnit: 1)?.accessibilityActivate()
		XCTAssertEqual(followed?.0, 1)
		XCTAssertEqual(followed?.1, 1)
	}

	func testDoubleTapOnAParagraphOpensTheMenu() {
		let view = structuredView()
		var opened = false
		view.onActivate = { opened = true }
		_ = view.element(forUnit: 4)?.accessibilityActivate()
		XCTAssertTrue(opened)
	}
}
