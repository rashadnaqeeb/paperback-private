import UIKit
import XCTest
@testable import Paperback

/// A book given as its buffer and markers, answering the percent the way the engine does.
private final class PagedSession: DocumentSession, @unchecked Sendable {
	var buffer = ""
	var markers: [LineMarker] = []

	override func content() -> String { buffer }
	override func getStructureMarkersFfi() -> [LineMarker] { markers }
	override func getStatusInfo(position: Int64) -> StatusInfo {
		StatusInfo(lineNumber: 0, characterNumber: position, percentage: Int32(position * 100 / Int64(buffer.unicodeScalars.count)))
	}
}

@MainActor
final class PageTests: XCTestCase {
	// Ten paragraphs of ten characters ("Para 0...\n"); book pages start at paragraphs 0, 4, and 7.
	private func session(pages: Bool) -> PagedSession {
		let session = PagedSession(noHandle: .init())
		session.buffer = (0..<10).map { "Para \($0)...." }.joined(separator: "\n")
		if pages {
			for (paragraph, label) in [(0, "i"), (4, "1"), (7, "2")] {
				session.markers.append(LineMarker(mtype: .pageBreak, position: Int64(paragraph * 11), text: label, reference: "", level: 0, length: 0))
			}
		}
		return session
	}

	private func controller(pages: Bool, start: Int) -> (ReadingViewController, BookView) {
		let controller = ReadingViewController(model: BookModel(session: session(pages: pages)), startUnit: start)
		let view = controller.view as! BookView
		view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
		view.layoutIfNeeded()
		return (controller, view)
	}

	func testTheModelKnowsTheBooksPages() {
		let model = BookModel(session: session(pages: true))
		XCTAssertEqual(model.pageLabels, ["i", "1", "2"])
		XCTAssertEqual(model.page(atPosition: 50), 1)
		XCTAssertEqual(model.pageStop(from: 0, forward: true), 4)
		XCTAssertEqual(model.pageStop(from: 5, forward: true), 7)
		XCTAssertEqual(model.pageStop(from: 5, forward: false), 4)
		XCTAssertNil(model.pageStop(from: 8, forward: true))
	}

	func testTheTapSpeaksThePrintedPageAndThePercent() {
		let (controller, view) = controller(pages: true, start: 5)
		XCTAssertEqual(controller.status(), "Page 1, 50 percent")
		XCTAssertEqual(controller.accessibilityScrollStatus(for: view), controller.status())
	}

	func testWithoutPrintedPagesTheTapSpeaksThePercent() {
		let (controller, _) = controller(pages: false, start: 5)
		XCTAssertEqual(controller.status(), "50 percent")
	}

	func testAThreeFingerFlickUpGoesToTheNextPrintedPage() {
		let (controller, view) = controller(pages: true, start: 5)
		var saved: [Int64] = []
		controller.onPositionChange = { saved.append($0) }
		XCTAssertTrue(view.accessibilityScroll(.up))
		XCTAssertEqual(view.focusedUnit, 7)
		XCTAssertEqual(saved, [77])
		XCTAssertFalse(view.accessibilityScroll(.up))
		XCTAssertTrue(view.accessibilityScroll(.down))
		XCTAssertEqual(view.focusedUnit, 4)
	}

	func testReadAllsOwnPageTurnsAreLeftAlone() {
		let (_, view) = controller(pages: true, start: 5)
		XCTAssertFalse(view.accessibilityScroll(.next))
		XCTAssertEqual(view.focusedUnit, 5)
	}

	func testThePageNeverScrollsAway() {
		let (_, view) = controller(pages: false, start: 0)
		view.contentOffset = CGPoint(x: 0, y: 3000)
		view.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
		view.scrollRectToVisible(CGRect(x: 0, y: 5000, width: 10, height: 10), animated: false)
		XCTAssertEqual(view.contentOffset, .zero)
	}

	func testTheBookmarksRotorMovesBetweenBookmarksAndRecordsTheJump() {
		let (controller, view) = controller(pages: false, start: 0)
		controller.bookmarkPositions = { [66, 22] }
		var jumpedFrom: [Int] = []
		view.onRotorJump = { jumpedFrom.append($0) }
		let rotor = view.accessibilityCustomRotors?.first { $0.name == t("Bookmarks") }
		let predicate = UIAccessibilityCustomRotorSearchPredicate()
		predicate.searchDirection = .next
		predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: view.element(forUnit: 3)!, targetRange: nil)
		XCTAssertEqual((rotor?.itemSearchBlock(predicate)?.targetElement as? ParagraphElement)?.unit, 6)
		XCTAssertEqual(jumpedFrom, [3])
	}
}
