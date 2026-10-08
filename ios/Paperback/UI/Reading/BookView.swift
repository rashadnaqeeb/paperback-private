import UIKit

/// The reading surface: the whole book as one lazy accessibility container over a page of laid-out units.
///
/// VoiceOver is told the book's full block count but elements are made only when it asks for them, and only a window
/// around the reading position is kept. The page showing is real: every unit on it is drawn and touchable at its true
/// rectangle. Every other unit claims a rectangle whole screen-heights above or below, never on screen, because
/// VoiceOver's periodic reconciliation snaps focus back to whatever claims to be on screen. When focus leaves the page,
/// the page turns to it, so Read All and flicking carry the text along.
///
/// The container's own elements are the book's blocks: a paragraph, or a list or table holding its items or cells.
/// The rotors are the app's own, worked out from the book model's maps, never by VoiceOver scanning elements, which
/// lags out on a whole book.
///
/// It is a scroll view only so VoiceOver asks it for the three-finger tap's status and sends it three-finger flicks;
/// it never scrolls, since pages turn by laying out again.
@MainActor
final class BookView: UIScrollView {
	let model: BookModel

	private(set) var focusedUnit = 0
	private var pageStart = 0
	/// Frames of the units on the page, from `pageStart` on, in this view's coordinates.
	private var pageFrames: [CGRect] = []
	private var labels: [UILabel] = []
	private var liveElements: [Int: ParagraphElement] = [:]
	private var liveLinks: [Int: [Int: LinkElement]] = [:]
	private var liveBlocks: [Int: UIAccessibilityElement] = [:]
	private var liveCells: [Int: [Int: TableCellElement]] = [:]
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
	/// A three-finger flick, forward or back, reporting whether there was a page to go to.
	var onPageScroll: ((Bool) -> Bool)?
	/// Where the reader's bookmarks are, for the Bookmarks rotor.
	var bookmarkPositions: () -> [Int64] = { [] }

	init(model: BookModel) {
		self.model = model
		super.init(frame: .zero)
		isAccessibilityElement = false
		backgroundColor = .systemBackground
		isScrollEnabled = false
		scrollsToTop = false
		showsVerticalScrollIndicator = false
		showsHorizontalScrollIndicator = false
		contentInsetAdjustmentBehavior = .never
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

	private func font(for kind: UnitKind, header: Bool = false) -> UIFont {
		let style: UIFont.TextStyle
		var traits: UIFontDescriptor.SymbolicTraits = []
		switch kind {
		case .heading(let level):
			style = level == 1 ? .title1 : level == 2 ? .title2 : level == 3 ? .title3 : .headline
			traits = .traitBold
		case .image:
			style = .callout
			traits = .traitItalic
		case .caption:
			style = .subheadline
			traits = .traitBold
		case .tableRow:
			style = .subheadline
			if header { traits = .traitBold }
		case .paragraph, .listItem:
			style = .body
		}
		let font = UIFont.preferredFont(forTextStyle: style)
		guard !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
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

	private func configure(_ label: UILabel, forCell cell: ParsedTable.Cell, kind: UnitKind) {
		label.attributedText = NSAttributedString(string: cell.text, attributes: [.font: font(for: kind, header: cell.isHeader), .foregroundColor: UIColor.label])
		label.numberOfLines = 0
	}

	/// The table and row a unit lays out, when it is a table row.
	private func tableRow(_ index: Int) -> (table: ParsedTable, row: Int)? {
		guard case .tableRow(let table, let row) = model.units[index].kind else { return nil }
		return (model.tables[table], row)
	}

	private func height(ofUnit index: Int, width: CGFloat) -> CGFloat {
		if width != measuredWidth {
			heights.removeAll()
			measuredWidth = width
		}
		if let known = heights[index] { return known }
		var height: CGFloat = 0
		if let (table, row) = tableRow(index) {
			// A row is as tall as its tallest cell; cells spanning rows are measured in the row they start in.
			let column = width / CGFloat(table.columnCount)
			for cell in table.rows[row] {
				configure(sizingLabel, forCell: cell, kind: model.units[index].kind)
				height = max(height, sizingLabel.sizeThatFits(CGSize(width: column * CGFloat(cell.columnSpan) - 6, height: .greatestFiniteMagnitude)).height)
			}
			height = ceil(height)
		} else {
			configure(sizingLabel, forUnit: index)
			height = ceil(sizingLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
		}
		heights[index] = height
		return height
	}

	/// The space after a unit: a table's rows sit close together.
	private func gap(after index: Int) -> CGFloat {
		if tableRow(index) != nil, index + 1 < model.count, tableRow(index + 1) != nil, model.blockOfUnit[index] == model.blockOfUnit[index + 1] {
			return paragraphGap / 3
		}
		return paragraphGap
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
			y += height + gap(after: index)
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
			let previous = height(ofUnit: start - 1, width: area.width) + gap(after: start - 1)
			if used + previous > area.height { break }
			used += previous
			start -= 1
		}
		return start
	}

	private func showPage(from start: Int) {
		pageStart = min(max(start, 0), max(model.count - 1, 0))
		pageFrames = pageFrames(from: pageStart)
		var used = 0
		func nextLabel() -> UILabel {
			if used == labels.count {
				let label = UILabel()
				label.isAccessibilityElement = false
				addSubview(label)
				labels.append(label)
			}
			used += 1
			return labels[used - 1]
		}
		for (offset, frame) in pageFrames.enumerated() {
			let index = pageStart + offset
			if let (table, row) = tableRow(index) {
				for cell in table.rows[row] {
					let label = nextLabel()
					configure(label, forCell: cell, kind: model.units[index].kind)
					label.frame = cellFrame(column: cell.column, span: cell.columnSpan, of: table.columnCount, in: frame).insetBy(dx: 3, dy: 0)
					label.isHidden = false
				}
			} else {
				let label = nextLabel()
				configure(label, forUnit: index)
				label.frame = frame
				label.isHidden = false
			}
		}
		for label in labels[used...] {
			label.isHidden = true
		}
	}

	/// Pinned: VoiceOver may try to scroll toward an element off the page, which would only slide the drawn page away.
	override var contentOffset: CGPoint {
		get { .zero }
		set { super.contentOffset = .zero }
	}

	override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {}

	override func layoutSubviews() {
		super.layoutSubviews()
		contentSize = bounds.size
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

	/// Where a run of units is: the part of it on the page, or where its first unit is when none of it is.
	func frame(forUnits units: Range<Int>) -> CGRect {
		let onPage = units.filter(isOnPage)
		guard let first = onPage.first, let last = onPage.last else { return frame(forUnit: units.lowerBound) }
		return frame(forUnit: first).union(frame(forUnit: last))
	}

	private func cellFrame(column: Int, span: Int, of columns: Int, in row: CGRect) -> CGRect {
		let width = row.width / CGFloat(max(columns, 1))
		return CGRect(x: row.minX + CGFloat(column) * width, y: row.minY, width: width * CGFloat(span), height: row.height)
	}

	func frame(forCellAt column: Int, span: Int, of columns: Int, rows: Range<Int>) -> CGRect {
		cellFrame(column: column, span: span, of: columns, in: frame(forUnits: rows))
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

	// MARK: Elements

	/// The element VoiceOver lands on for a unit: the unit's own, or the first cell of a table row.
	func focusTarget(forUnit index: Int) -> NSObject? {
		guard model.units.indices.contains(index) else { return nil }
		guard case .tableRow(_, let row) = model.units[index].kind else { return element(forUnit: index) }
		guard let table = blockElement(model.blockOfUnit[index]) as? TableElement, let first = table.table.rows[row].first else { return nil }
		return cellElement(row: row, column: first.column, table: table)
	}

	/// The container a unit's element sits in: its list, or this view.
	private func container(forUnit index: Int) -> Any {
		let block = model.blockOfUnit[index]
		return model.blocks[block].kind == .list ? (blockElement(block) ?? self) : self
	}

	/// A paragraph, heading, image, list item, or caption's element, made if it has not been handed out yet.
	func element(forUnit index: Int) -> ParagraphElement? {
		guard model.units.indices.contains(index), tableRow(index) == nil else { return nil }
		if let live = liveElements[index] { return live }
		let element = ParagraphElement(container: container(forUnit: index), bookView: self, unit: index, unit: model.units[index])
		liveElements[index] = element
		trimElements()
		return element
	}

	func element(forLink link: Int, inUnit unit: Int) -> LinkElement? {
		guard model.units.indices.contains(unit), model.units[unit].links.indices.contains(link) else { return nil }
		if let live = liveLinks[unit]?[link] { return live }
		let element = LinkElement(container: container(forUnit: unit), bookView: self, unit: unit, link: link, text: model.units[unit].links[link].text)
		liveLinks[unit, default: [:]][link] = element
		return element
	}

	/// A block's element: its paragraph's own, or the container of its list or table.
	func blockElement(_ block: Int) -> NSObject? {
		guard model.blocks.indices.contains(block) else { return nil }
		let units = model.blocks[block].units
		switch model.blocks[block].kind {
		case .single:
			return element(forUnit: units.lowerBound)
		case .list:
			if let live = liveBlocks[block] { return live }
			let list = ListElement(bookView: self, block: block, units: units)
			liveBlocks[block] = list
			return list
		case .table(let table):
			if let live = liveBlocks[block] { return live }
			let element = TableElement(bookView: self, block: block, table: model.tables[table], firstUnit: units.lowerBound)
			liveBlocks[block] = element
			return element
		}
	}

	func cellElement(row: Int, column: Int, table: TableElement) -> TableCellElement? {
		let unit = table.firstUnit + row
		if let live = liveCells[unit]?[column] { return live }
		guard let cell = table.table.rows[row].first(where: { $0.column == column }) else { return nil }
		let element = TableCellElement(table: table, cell: cell, bookView: self)
		liveCells[unit, default: [:]][column] = element
		return element
	}

	private func trimElements() {
		guard liveElements.count + liveCells.count > windowRadius * 2 else { return }
		for index in liveElements.keys where abs(index - focusedUnit) > windowRadius {
			liveElements.removeValue(forKey: index)
		}
		for index in liveLinks.keys where abs(index - focusedUnit) > windowRadius {
			liveLinks.removeValue(forKey: index)
		}
		for index in liveCells.keys where abs(index - focusedUnit) > windowRadius {
			liveCells.removeValue(forKey: index)
		}
		for block in liveBlocks.keys where abs(model.blocks[block].units.lowerBound - focusedUnit) > windowRadius && !model.blocks[block].units.contains(focusedUnit) {
			liveBlocks.removeValue(forKey: block)
		}
	}

	// MARK: UIAccessibilityContainer

	override func accessibilityElementCount() -> Int {
		model.blocks.count
	}

	override func accessibilityElement(at index: Int) -> Any? {
		blockElement(index)
	}

	override func index(ofAccessibilityElement element: Any) -> Int {
		switch element {
		case let list as ListElement: return list.block
		case let table as TableElement: return table.block
		case let element as BookElement where model.blockOfUnit.indices.contains(element.unit): return model.blockOfUnit[element.unit]
		default: return NSNotFound
		}
	}

	/// The two-finger scrub jumps back.
	override func accessibilityPerformEscape() -> Bool {
		onEscape?() ?? false
	}

	/// Three-finger flicks up and down move by page. Read All's own page turns (next and previous) are left alone:
	/// the page already follows focus.
	override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
		switch direction {
		case .up: onPageScroll?(true) ?? false
		case .down: onPageScroll?(false) ?? false
		default: false
		}
	}

	/// The first unit of the visual page after this one, or of the one before.
	func visualPageStop(forward: Bool) -> Int? {
		if forward { return lastUnitOnPage + 1 < model.count ? lastUnitOnPage + 1 : nil }
		return pageStart > 0 ? pageStart(endingAt: pageStart - 1) : nil
	}

	/// Touch exploration asks only about the page showing; left to itself, VoiceOver would walk every element in the
	/// book to find the one under a finger.
	@available(iOS 18.0, *)
	override func accessibilityHitTest(_ point: CGPoint, event: UIEvent?) -> Any? {
		guard let offset = pageFrames.firstIndex(where: { $0.contains(point) }) else { return nil }
		let index = pageStart + offset
		guard let (table, row) = tableRow(index), let element = blockElement(model.blockOfUnit[index]) as? TableElement else {
			return element(forUnit: index)
		}
		let frame = pageFrames[offset]
		let column = min(Int((point.x - frame.minX) / (frame.width / CGFloat(table.columnCount))), table.columnCount - 1)
		guard let cell = table.cell(row: row, column: column) else { return nil }
		return cellElement(row: cell.row, column: cell.column, table: element)
	}

	// MARK: Rotors

	override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
		get { rotors }
		set {}
	}

	private lazy var rotors: [UIAccessibilityCustomRotor] = [
		// TRANSLATORS: Name of the VoiceOver rotor setting that moves by paragraph in a book; a list or table counts as one
		unitRotor(name: t("Paragraphs"), isJump: false) { view, from, forward in view.model.blockStart(from: from, forward: forward) },
		unitRotor(systemType: .heading, isJump: true) { view, from, forward in BookModel.stop(in: view.model.headingUnits, from: from, forward: forward) },
		linkRotor(),
		unitRotor(systemType: .table, isJump: false) { view, from, forward in view.structureStop(view.model.tableUnits, from: from, forward: forward) },
		unitRotor(systemType: .list, isJump: false) { view, from, forward in view.structureStop(view.model.listUnits, from: from, forward: forward) },
		unitRotor(systemType: .image, isJump: false) { view, from, forward in BookModel.stop(in: view.model.imageUnits, from: from, forward: forward) },
		// TRANSLATORS: Name of the VoiceOver rotor setting that moves between the reader's bookmarks in a book
		unitRotor(name: t("Bookmarks"), isJump: true) { view, from, forward in
			BookModel.stop(in: Set(view.bookmarkPositions().map(view.model.unit(forPosition:))).sorted(), from: from, forward: forward)
		},
	]

	/// The next or previous list or table, counted from the start of the one the origin is inside.
	private func structureStop(_ stops: [Int], from: Int, forward: Bool) -> Int? {
		let start = model.blocks[model.blockOfUnit[from]].units.lowerBound
		return BookModel.stop(in: stops, from: forward ? max(from, start) : start, forward: forward)
	}

	/// The unit a rotor search starts from: the rotor's last target, else wherever focus is.
	private func origin(of predicate: UIAccessibilityCustomRotorSearchPredicate) -> Int {
		(predicate.currentItem.targetElement as? BookElement)?.unit ?? focusedUnit
	}

	/// A rotor moving between units, named for a custom rotor or typed for one of VoiceOver's own.
	private func unitRotor(name: String? = nil, systemType: UIAccessibilityCustomRotor.SystemRotorType = .none, isJump: Bool, next: @escaping (BookView, Int, Bool) -> Int?) -> UIAccessibilityCustomRotor {
		let search: UIAccessibilityCustomRotor.Search = { [weak self] predicate in
			guard let self else { return nil }
			let from = origin(of: predicate)
			guard let target = next(self, from, predicate.searchDirection == .next), let element = focusTarget(forUnit: target) else { return nil }
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
