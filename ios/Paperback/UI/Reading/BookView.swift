import UIKit

/// The reading surface: the whole book as one lazy accessibility container over a page of laid-out units.
///
/// VoiceOver is told the book's full element count but elements are made only when it asks for them, and only a
/// window around the reading position is kept. The page showing is real: every unit on it is drawn and touchable at
/// its true rectangle. Every other unit claims a rectangle whole screen-heights above or below, never on screen,
/// because VoiceOver's periodic reconciliation snaps focus back to whatever claims to be on screen. When focus leaves
/// the page, the page turns to it, so Read All and flicking carry the text along.
///
/// The rotors are the app's own, worked out from the book model's maps, never by VoiceOver scanning elements, which
/// lags out on a whole book.
@MainActor
final class BookView: UIView {
	let model: BookModel

	private(set) var focusedUnit = 0
	private var pageStart = 0
	/// Frames of the units on the page, from `pageStart` on, in this view's coordinates.
	private var pageFrames: [CGRect] = []
	private var labels: [UILabel] = []
	private var liveElements: [Int: ParagraphElement] = [:]
	private var liveLinks: [Int: [Int: LinkElement]] = [:]
	private let windowRadius = 128
	private var heights: [Int: CGFloat] = [:]
	private var measuredWidth: CGFloat = 0
	private let sizingLabel = UILabel()

	var onFocusChange: ((Int) -> Void)?
	var onActivate: (() -> Void)?
	var onEscape: (() -> Bool)?
	/// A link to follow, as its unit and its index among the unit's links.
	var onFollowLink: ((Int, Int) -> Void)?
	/// A rotor jump the scrub should be able to undo, with the unit it left.
	var onRotorJump: ((Int) -> Void)?

	init(model: BookModel) {
		self.model = model
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

	/// The area units are laid out in: inside the safe area and the readable margins.
	private var textArea: CGRect {
		let safe = bounds.inset(by: safeAreaInsets)
		return safe.inset(by: UIEdgeInsets(top: 16, left: layoutMargins.left, bottom: 16, right: layoutMargins.right))
	}

	private var paragraphGap: CGFloat { UIFont.preferredFont(forTextStyle: .body).lineHeight * 0.6 }

	private func font(for kind: UnitKind) -> UIFont {
		let style: UIFont.TextStyle
		switch kind {
		case .heading(1): style = .title1
		case .heading(2): style = .title2
		case .heading(3): style = .title3
		case .heading: style = .headline
		case .image: style = .callout
		case .paragraph: style = .body
		}
		let font = UIFont.preferredFont(forTextStyle: style)
		let traits: UIFontDescriptor.SymbolicTraits
		switch kind {
		case .heading: traits = .traitBold
		case .image: traits = .traitItalic
		case .paragraph: return font
		}
		guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
		return UIFont(descriptor: descriptor, size: 0)
	}

	private func configure(_ label: UILabel, forUnit index: Int) {
		let unit = model.units[index]
		let text = NSMutableAttributedString(string: unit.text, attributes: [.font: font(for: unit.kind), .foregroundColor: UIColor.label])
		for link in unit.links {
			text.addAttributes([.foregroundColor: UIColor.link, .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(link.range, in: unit.text))
		}
		label.attributedText = text
		label.numberOfLines = 0
	}

	private func height(ofUnit index: Int, width: CGFloat) -> CGFloat {
		if width != measuredWidth {
			heights.removeAll()
			measuredWidth = width
		}
		if let known = heights[index] { return known }
		configure(sizingLabel, forUnit: index)
		let height = ceil(sizingLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
		heights[index] = height
		return height
	}

	/// Lays out a page from `start`: every unit that fits whole, and always the first, however tall.
	private func pageFrames(from start: Int) -> [CGRect] {
		let area = textArea
		guard area.width > 0, start < model.count else { return [] }
		var frames: [CGRect] = []
		var y = area.minY
		var index = start
		while index < model.count {
			let height = height(ofUnit: index, width: area.width)
			if !frames.isEmpty, y + height > area.maxY { break }
			frames.append(CGRect(x: area.minX, y: y, width: area.width, height: height))
			y += height + paragraphGap
			index += 1
		}
		return frames
	}

	/// The first unit of the page that ends with `index`, for turning back a page.
	private func pageStart(endingAt index: Int) -> Int {
		let area = textArea
		var used = height(ofUnit: index, width: area.width)
		var start = index
		while start > 0 {
			let previous = height(ofUnit: start - 1, width: area.width) + paragraphGap
			if used + previous > area.height { break }
			used += previous
			start -= 1
		}
		return start
	}

	private func showPage(from start: Int) {
		pageStart = min(max(start, 0), max(model.count - 1, 0))
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
			configure(label, forUnit: pageStart + offset)
			label.frame = pageFrames[offset]
			label.isHidden = false
		}
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		showPage(from: pageStart)
		// A taller text size or a rotation can push the focused unit off the page it was on.
		if !isOnPage(focusedUnit) { showPage(from: focusedUnit) }
	}

	private func isOnPage(_ index: Int) -> Bool {
		index >= pageStart && index < pageStart + pageFrames.count
	}

	/// Where a unit is: its real rectangle when it is on the page, else whole screen-heights above or below.
	func frame(forUnit index: Int) -> CGRect {
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
		guard model.count > 0 else { return }
		let index = min(max(index, 0), model.count - 1)
		focusedUnit = index
		if pageFrames.isEmpty { pageStart = index }
		guard !isOnPage(index) else { return }
		showPage(from: index < pageStart ? pageStart(endingAt: index) : index)
	}

	var lastUnitOnPage: Int { pageStart + max(pageFrames.count - 1, 0) }
	var firstUnitOnPage: Int { pageStart }

	/// Turns to the next or previous page, for reading without VoiceOver.
	func turnPage(forward: Bool) {
		if forward {
			guard lastUnitOnPage + 1 < model.count else { return }
			showPage(from: lastUnitOnPage + 1)
		} else {
			guard pageStart > 0 else { return }
			showPage(from: pageStart(endingAt: pageStart - 1))
		}
		focusedUnit = pageStart
	}

	func unitBecameFocused(_ index: Int) {
		reveal(index)
		trimElements()
		onFocusChange?(index)
	}

	/// The element VoiceOver lands on for a unit, made if it has not been handed out yet.
	func element(forUnit index: Int) -> ParagraphElement? {
		guard model.units.indices.contains(index) else { return nil }
		if let live = liveElements[index] { return live }
		let element = ParagraphElement(container: self, bookView: self, unit: index, unit: model.units[index])
		liveElements[index] = element
		trimElements()
		return element
	}

	func element(forLink link: Int, inUnit unit: Int) -> LinkElement? {
		guard model.units.indices.contains(unit), model.units[unit].links.indices.contains(link) else { return nil }
		if let live = liveLinks[unit]?[link] { return live }
		let element = LinkElement(container: self, bookView: self, unit: unit, link: link, text: model.units[unit].links[link].text)
		liveLinks[unit, default: [:]][link] = element
		return element
	}

	private func trimElements() {
		guard liveElements.count > windowRadius * 2 else { return }
		for index in liveElements.keys where abs(index - focusedUnit) > windowRadius {
			liveElements.removeValue(forKey: index)
		}
		for index in liveLinks.keys where abs(index - focusedUnit) > windowRadius {
			liveLinks.removeValue(forKey: index)
		}
	}

	// MARK: UIAccessibilityContainer

	override func accessibilityElementCount() -> Int {
		model.count
	}

	override func accessibilityElement(at index: Int) -> Any? {
		element(forUnit: index)
	}

	override func index(ofAccessibilityElement element: Any) -> Int {
		(element as? BookElement)?.unit ?? NSNotFound
	}

	/// The two-finger scrub jumps back.
	override func accessibilityPerformEscape() -> Bool {
		onEscape?() ?? false
	}

	/// Touch exploration asks only about the page showing; left to itself, VoiceOver would walk every element in the
	/// book to find the one under a finger.
	@available(iOS 18.0, *)
	override func accessibilityHitTest(_ point: CGPoint, event: UIEvent?) -> Any? {
		guard let offset = pageFrames.firstIndex(where: { $0.contains(point) }) else { return nil }
		return element(forUnit: pageStart + offset)
	}

	// MARK: Rotors

	override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
		get { rotors }
		set {}
	}

	private lazy var rotors: [UIAccessibilityCustomRotor] = [
		// TRANSLATORS: Name of the VoiceOver rotor setting that moves by paragraph in a book
		unitRotor(name: t("Paragraphs"), stops: nil, isJump: false),
		unitRotor(systemType: .heading, stops: { $0.model.headingUnits }, isJump: true),
		linkRotor(),
		unitRotor(systemType: .image, stops: { $0.model.imageUnits }, isJump: false),
	]

	/// The unit a rotor search starts from: the rotor's last target, else wherever focus is.
	private func origin(of predicate: UIAccessibilityCustomRotorSearchPredicate) -> Int {
		(predicate.currentItem.targetElement as? BookElement)?.unit ?? focusedUnit
	}

	/// A rotor moving between units, named for a custom rotor or typed for one of VoiceOver's own. Nil stops moves by
	/// every unit.
	private func unitRotor(name: String? = nil, systemType: UIAccessibilityCustomRotor.SystemRotorType = .none, stops: ((BookView) -> [Int])?, isJump: Bool) -> UIAccessibilityCustomRotor {
		let search: UIAccessibilityCustomRotor.Search = { [weak self] predicate in
			guard let self else { return nil }
			let from = origin(of: predicate)
			let forward = predicate.searchDirection == .next
			let target: Int?
			if let stops {
				target = BookModel.stop(in: stops(self), from: from, forward: forward)
			} else {
				let next = from + (forward ? 1 : -1)
				target = model.units.indices.contains(next) ? next : nil
			}
			guard let target, let element = element(forUnit: target) else { return nil }
			if isJump { onRotorJump?(from) }
			return UIAccessibilityCustomRotorItemResult(targetElement: element, targetRange: nil)
		}
		if let name { return UIAccessibilityCustomRotor(name: name, itemSearch: search) }
		return UIAccessibilityCustomRotor(systemType: systemType, itemSearch: search)
	}

	/// Moves between individual links, landing on each one inside its paragraph.
	private func linkRotor() -> UIAccessibilityCustomRotor {
		UIAccessibilityCustomRotor(systemType: .link) { [weak self] predicate in
			guard let self else { return nil }
			let current = predicate.currentItem.targetElement
			let unit = (current as? BookElement)?.unit ?? focusedUnit
			// Before every link of a paragraph when on the paragraph itself, so the first link counts as next.
			let link = (current as? LinkElement)?.link ?? -1
			let stops = model.linkStops
			let forward = predicate.searchDirection == .next
			let found = forward
				? stops.first { $0.unit > unit || ($0.unit == unit && $0.link > link) }
				: stops.last { $0.unit < unit || ($0.unit == unit && $0.link < link && link >= 0) }
			guard let found, let element = element(forLink: found.link, inUnit: found.unit) else { return nil }
			return UIAccessibilityCustomRotorItemResult(targetElement: element, targetRange: nil)
		}
	}
}
