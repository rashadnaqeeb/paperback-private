import XCTest
@testable import Paperback

final class SegmentTypeNameTests: XCTestCase {
	private static let allTypes: [SegmentTypeFfi] = [
		.paragraph, .line, .heading, .link, .section, .page,
		.list, .listItem, .table, .separator, .image, .figure, .formula,
	]

	/// The reading bar's unit picker lists every unit by name, so a type with no name of its own would leave an entry announcing nothing useful.
	func testEveryTypeTheCoreCanReportHasAName() {
		for type in Self.allTypes {
			XCTAssertFalse(segmentTypeName(type).isEmpty, "\(type) has no name")
		}
	}

	/// Two units reading alike in the picker would be indistinguishable to a screen reader,
	/// which is the only way most readers tell them apart.
	func testNoTwoTypesShareAName() {
		let names = Self.allTypes.map { segmentTypeName($0) }
		XCTAssertEqual(Self.allTypes.count, Set(names).count, "duplicate names in \(names)")
	}
}

final class NavUnitNameTests: XCTestCase {
	/// Find joins the unit list whenever a search is active, so it has to be distinguishable
	/// from every structural unit it sits beside.
	func testFindDoesNotShareANameWithAStructuralUnit() {
		let findName = NavUnit.find.name
		XCTAssertFalse(findName.isEmpty)
		for type in [SegmentTypeFfi.paragraph, .line, .heading, .section] {
			XCTAssertNotEqual(findName, NavUnit.segment(type).name)
		}
	}

	/// A recorded book offers seek amounts in the same list as its structural units, so the two
	/// kinds must not produce the same label either.
	func testSeekAmountsDoNotShareNamesWithStructuralUnits() {
		let segmentNames = Set([SegmentTypeFfi.paragraph, .line, .section].map { NavUnit.segment($0).name })
		for seconds in audioSeekAmountsSeconds {
			XCTAssertFalse(segmentNames.contains(NavUnit.time(seconds: seconds).name))
		}
	}

	/// A unit's name is what the previous and next buttons announce, so an unnamed one would
	/// leave them reading "Previous" and "Next" with nothing after.
	func testEveryOfferedSeekAmountIsNamed() {
		for seconds in audioSeekAmountsSeconds {
			XCTAssertFalse(NavUnit.time(seconds: seconds).name.isEmpty, "\(seconds)s has no name")
		}
	}
}
