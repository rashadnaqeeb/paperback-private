import UIKit

/// One VoiceOver element per paragraph. Instances are cheap and disposable: equality and hashing are by element index,
/// so VoiceOver treats a re-created element as the one it saw before the window let it go.
@MainActor
final class ParagraphElement: UIAccessibilityElement {
	let index: Int

	init(container: BookView, index: Int, text: String, headingLevel: Int?) {
		self.index = index
		super.init(accessibilityContainer: container)
		if let headingLevel {
			accessibilityAttributedLabel = NSAttributedString(string: text, attributes: [.accessibilityTextHeadingLevel: headingLevel])
			accessibilityTraits = .header
		} else {
			accessibilityLabel = text
			accessibilityTraits = .staticText
		}
	}

	nonisolated override func isEqual(_ object: Any?) -> Bool {
		(object as? ParagraphElement)?.index == index
	}

	nonisolated override var hash: Int { index }

	/// Computed on demand so the frame always matches the page now showing.
	override var accessibilityFrame: CGRect {
		get {
			guard let container = accessibilityContainer as? BookView else { return .zero }
			return UIAccessibility.convertToScreenCoordinates(container.frame(forElement: index), in: container)
		}
		set {}
	}

	override func accessibilityElementDidBecomeFocused() {
		(accessibilityContainer as? BookView)?.elementBecameFocused(index)
	}

	/// Double-tap on any paragraph opens the in-book menu.
	override func accessibilityActivate() -> Bool {
		(accessibilityContainer as? BookView)?.onActivate?()
		return true
	}
}

/// The reading surface: the whole book as one lazy accessibility container over a page of laid-out paragraphs.
///
/// VoiceOver is told the book's full element count but elements are made only when it asks for them, and only a
/// window around the reading position is kept. The page showing is real: every paragraph on it is drawn and touchable
/// at its true rectangle. Every other paragraph claims a rectangle whole screen-heights above or below, never on
/// screen, because VoiceOver's periodic reconciliation snaps focus back to whatever claims to be on screen. When focus
/// leaves the page, the page turns to it, so Read All and flicking carry the text along.
@MainActor
final class BookView: UIView {
	let text: BookText

	private(set) var focusedIndex = 0
	private var pageStart = 0
	/// Frames of the paragraphs on the page, from `pageStart` on, in this view's coordinates.
	private var pageFrames: [CGRect] = []
	private var labels: [UILabel] = []
	private var liveElements: [Int: ParagraphElement] = [:]
	private let windowRadius = 128
	private var heights: [Int: CGFloat] = [:]
	private var measuredWidth: CGFloat = 0
	private let sizingLabel = UILabel()

	var onFocusChange: ((Int) -> Void)?
	var onActivate: (() -> Void)?
	var onEscape: (() -> Void)?

	init(text: BookText) {
		self.text = text
		super.init(frame: .zero)
		isAccessibilityElement = false
		backgroundColor = .systemBackground
		sizingLabel.numberOfLines = 0
		registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: BookView, _) in
			view.heights.removeAll()
			view.setNeedsLayout()
		}
	}

	required init?(coder: NSCoder) { fatalError("not used") }

	// MARK: Layout

	/// The area paragraphs are laid out in: inside the safe area and the readable margins.
	private var textArea: CGRect {
		let safe = bounds.inset(by: safeAreaInsets)
		return safe.inset(by: UIEdgeInsets(top: 16, left: layoutMargins.left, bottom: 16, right: layoutMargins.right))
	}

	private var paragraphGap: CGFloat { UIFont.preferredFont(forTextStyle: .body).lineHeight * 0.6 }

	private func font(forHeadingLevel level: Int?) -> UIFont {
		let style: UIFont.TextStyle = switch level {
		case 1?: .title1
		case 2?: .title2
		case 3?: .title3
		case .some: .headline
		case nil: .body
		}
		let font = UIFont.preferredFont(forTextStyle: style)
		guard level != nil, let bold = font.fontDescriptor.withSymbolicTraits(.traitBold) else { return font }
		return UIFont(descriptor: bold, size: 0)
	}

	private func configure(_ label: UILabel, forElement index: Int) {
		label.text = text.text(at: index)
		label.font = font(forHeadingLevel: text.headingLevel(at: index))
		label.textColor = .label
		label.numberOfLines = 0
	}

	private func height(ofElement index: Int, width: CGFloat) -> CGFloat {
		if width != measuredWidth {
			heights.removeAll()
			measuredWidth = width
		}
		if let known = heights[index] { return known }
		configure(sizingLabel, forElement: index)
		let height = ceil(sizingLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
		heights[index] = height
		return height
	}

	/// Lays out a page from `start`: every paragraph that fits whole, and always the first, however tall.
	private func pageFrames(from start: Int) -> [CGRect] {
		let area = textArea
		guard area.width > 0, start < text.count else { return [] }
		var frames: [CGRect] = []
		var y = area.minY
		var index = start
		while index < text.count {
			let height = height(ofElement: index, width: area.width)
			if !frames.isEmpty, y + height > area.maxY { break }
			frames.append(CGRect(x: area.minX, y: y, width: area.width, height: height))
			y += height + paragraphGap
			index += 1
		}
		return frames
	}

	/// The first paragraph of the page that ends with `index`, for turning back a page.
	private func pageStart(endingAt index: Int) -> Int {
		let area = textArea
		var used = height(ofElement: index, width: area.width)
		var start = index
		while start > 0 {
			let previous = height(ofElement: start - 1, width: area.width) + paragraphGap
			if used + previous > area.height { break }
			used += previous
			start -= 1
		}
		return start
	}

	private func showPage(from start: Int) {
		pageStart = min(max(start, 0), max(text.count - 1, 0))
		pageFrames = pageFrames(from: pageStart)
		while labels.count < pageFrames.count {
			let label = UILabel()
			label.isAccessibilityElement = false
			addSubview(label)
			labels.append(label)
		}
		for (offset, label) in labels.enumerated() {
			guard offset < pageFrames.count else {
				label.isHidden = true
				continue
			}
			configure(label, forElement: pageStart + offset)
			label.frame = pageFrames[offset]
			label.isHidden = false
		}
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		showPage(from: pageStart)
		// A taller text size or a rotation can push the focused paragraph off the page it was on.
		if !isOnPage(focusedIndex) { showPage(from: focusedIndex) }
	}

	private func isOnPage(_ index: Int) -> Bool {
		index >= pageStart && index < pageStart + pageFrames.count
	}

	/// Where an element is: its real rectangle when it is on the page, else whole screen-heights above or below.
	func frame(forElement index: Int) -> CGRect {
		if isOnPage(index) { return pageFrames[index - pageStart] }
		let screen = max(bounds.height, 1)
		let area = textArea
		let y = index < pageStart
			? -CGFloat(pageStart - index) * screen
			: CGFloat(index - pageStart - pageFrames.count + 1) * screen
		return CGRect(x: area.minX, y: y, width: area.width, height: screen / 2)
	}

	// MARK: Moving through the book

	/// Brings `index` onto the page, turning forward so it starts the page or back so it ends it.
	func reveal(_ index: Int) {
		guard text.count > 0 else { return }
		let index = min(max(index, 0), text.count - 1)
		focusedIndex = index
		if pageFrames.isEmpty { pageStart = index }
		guard !isOnPage(index) else { return }
		showPage(from: index < pageStart ? pageStart(endingAt: index) : index)
	}

	var lastIndexOnPage: Int { pageStart + max(pageFrames.count - 1, 0) }
	var firstIndexOnPage: Int { pageStart }

	/// Turns to the next or previous page, for reading without VoiceOver.
	func turnPage(forward: Bool) {
		if forward {
			guard lastIndexOnPage + 1 < text.count else { return }
			showPage(from: lastIndexOnPage + 1)
		} else {
			guard pageStart > 0 else { return }
			showPage(from: pageStart(endingAt: pageStart - 1))
		}
		focusedIndex = pageStart
	}

	func elementBecameFocused(_ index: Int) {
		reveal(index)
		trimElements()
		onFocusChange?(index)
	}

	/// The element for an index, made if VoiceOver has not been handed it yet.
	func element(at index: Int) -> ParagraphElement? {
		guard index >= 0, index < text.count else { return nil }
		if let live = liveElements[index] { return live }
		let element = ParagraphElement(container: self, index: index, text: text.text(at: index), headingLevel: text.headingLevel(at: index))
		liveElements[index] = element
		trimElements()
		return element
	}

	private func trimElements() {
		guard liveElements.count > windowRadius * 2 else { return }
		for index in liveElements.keys where abs(index - focusedIndex) > windowRadius {
			liveElements.removeValue(forKey: index)
		}
	}

	// MARK: UIAccessibilityContainer

	override func accessibilityElementCount() -> Int {
		text.count
	}

	override func accessibilityElement(at index: Int) -> Any? {
		element(at: index)
	}

	override func index(ofAccessibilityElement element: Any) -> Int {
		(element as? ParagraphElement)?.index ?? NSNotFound
	}

	/// The two-finger scrub leaves the book.
	override func accessibilityPerformEscape() -> Bool {
		onEscape?()
		return onEscape != nil
	}

	/// Touch exploration asks only about the page showing; left to itself, VoiceOver would walk every element in the
	/// book to find the one under a finger.
	@available(iOS 18.0, *)
	override func accessibilityHitTest(_ point: CGPoint, event: UIEvent?) -> Any? {
		guard let offset = pageFrames.firstIndex(where: { $0.contains(point) }) else { return nil }
		return element(at: pageStart + offset)
	}
}
