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

	init(container: Any, bookView: BookView, unit index: Int, unit: BookUnit) {
		self.unit = index
		self.bookView = bookView
		isWholeLink = unit.isWholeLink
		super.init(accessibilityContainer: container)
		switch unit.kind {
		case .heading(let level):
			accessibilityAttributedLabel = NSAttributedString(string: unit.text, attributes: [.accessibilityTextHeadingLevel: level])
			accessibilityTraits = .header
		case .image(let description):
			// TRANSLATORS: Spoken for an image in a book that has no description
			accessibilityLabel = description ?? t("Image")
			accessibilityTraits = description == nil ? .staticText : .image
		case .paragraph:
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

	init(container: Any, bookView: BookView, unit: Int, link: Int, text: String) {
		self.unit = unit
		self.link = link
		self.bookView = bookView
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
