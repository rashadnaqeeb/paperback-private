import UIKit

/// An item in the in-book menu.
struct ReadingMenuItem {
	let title: String
	let action: () -> Void
}

/// Hosts the reading surface: lands VoiceOver on the saved paragraph, saves the position as focus moves, follows
/// links, keeps the jump-back stack the two-finger scrub walks, opens the menu on double-tap, and turns pages by swipe
/// for reading without VoiceOver.
@MainActor
final class ReadingViewController: UIViewController, UIScrollViewAccessibilityDelegate {
	private let bookView: BookView
	private var model: BookModel { bookView.model }
	private var currentUnit: Int

	/// The book position of the unit the reader is on, whenever it changes.
	var onPositionChange: ((Int64) -> Void)?
	var onMenu: (() -> Void)?
	var bookmarkPositions: () -> [Int64] = { [] } {
		didSet { bookView.bookmarkPositions = bookmarkPositions }
	}

	/// The printed page the reader last turned to, and the unit it landed on, since a page can start inside a paragraph.
	private var turnedTo: (unit: Int, page: Int)?

	/// Where each jump the app made left from, newest last, so the scrub can go back.
	private var jumpBack: [Int] = []
	private let jumpBackLimit = 100

	/// VoiceOver focuses the first element by itself when the screen appears, before the restore lands. Until focus
	/// reaches the restore target, those stray focus events must not be saved, or they overwrite the real position with
	/// the book's start. The restore is posted again a few times, then wherever the reader actually is counts.
	private var restoreTarget = 0
	private var hasRestored = false
	private var restoreAttemptsLeft = 3

	init(model: BookModel, startUnit: Int) {
		bookView = BookView(model: model)
		currentUnit = startUnit
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError("not used") }

	override func loadView() {
		view = bookView
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		bookView.onFocusChange = { [weak self] unit in
			self?.handleFocus(at: unit)
		}
		bookView.onActivate = { [weak self] in
			self?.onMenu?()
		}
		bookView.onEscape = { [weak self] in
			self?.goBack() ?? false
		}
		bookView.onFollowLink = { [weak self] unit, link in
			self?.followLink(link, inUnit: unit)
		}
		bookView.onRotorJump = { [weak self] from in
			self?.pushJumpBack(from)
		}
		bookView.onPageScroll = { [weak self] forward in
			self?.turnPage(forward: forward) ?? false
		}
		bookView.delegate = self
		let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
		view.addGestureRecognizer(tap)
		for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
			let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
			swipe.direction = direction
			view.addGestureRecognizer(swipe)
		}
		// Centered on the saved position before VoiceOver's first query, so the restored unit owns the screen from the
		// start.
		bookView.reveal(currentUnit)
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		restoreFocus()
	}

	/// Puts VoiceOver back on the reader's unit, on opening and on returning from a screen over the book.
	func restoreFocus() {
		restoreTarget = currentUnit
		hasRestored = false
		restoreAttemptsLeft = 3
		postRestoreFocus()
	}

	private func postRestoreFocus() {
		guard let element = bookView.focusTarget(forUnit: restoreTarget) else { return }
		UIAccessibility.post(notification: .screenChanged, argument: element)
	}

	private func handleFocus(at unit: Int) {
		if !hasRestored {
			if unit == restoreTarget || restoreAttemptsLeft == 0 {
				hasRestored = true
			} else {
				restoreAttemptsLeft -= 1
				postRestoreFocus()
				return
			}
		}
		setCurrent(unit)
	}

	private func setCurrent(_ unit: Int) {
		guard unit != currentUnit else { return }
		currentUnit = unit
		onPositionChange?(model.position(ofUnit: unit))
	}

	// MARK: Jumps

	/// Moves to a position the app chose (a table of contents entry, a search result), remembered for the scrub.
	func jump(toPosition position: Int64) {
		jump(to: model.unit(forPosition: position))
	}

	func jump(to unit: Int) {
		pushJumpBack(currentUnit)
		move(to: unit)
	}

	private func pushJumpBack(_ unit: Int) {
		if jumpBack.last != unit { jumpBack.append(unit) }
		if jumpBack.count > jumpBackLimit { jumpBack.removeFirst() }
	}

	/// Returns from the most recent jump, reporting whether there was one to return from.
	private func goBack() -> Bool {
		guard let unit = jumpBack.popLast() else { return false }
		move(to: unit)
		return true
	}

	/// Moves to a unit with VoiceOver focus following when the reading screen is showing.
	private func move(to unit: Int, startingPage: Bool = false) {
		bookView.reveal(unit, startingPage: startingPage)
		setCurrent(bookView.focusedUnit)
		restoreTarget = bookView.focusedUnit
		guard view.window != nil, let element = bookView.focusTarget(forUnit: restoreTarget) else { return }
		UIAccessibility.post(notification: .layoutChanged, argument: element)
	}

	private func followLink(_ link: Int, inUnit unit: Int) {
		guard model.units.indices.contains(unit), model.units[unit].links.indices.contains(link) else { return }
		let result = model.session.activateLink(position: model.units[unit].links[link].position)
		guard result.found else { return }
		switch result.action {
		case .internal:
			currentUnit = unit
			jump(toPosition: result.offset)
		case .external:
			if let url = URL(string: result.url) { UIApplication.shared.open(url) }
		case .notFound:
			break
		}
	}

	// MARK: Pages

	/// What the three-finger tap speaks: the book's page when it has its own, and how far through it the reader is.
	func status() -> String {
		let position = model.position(ofUnit: currentUnit)
		let percent = model.session.getStatusInfo(position: position).percentage
		// TRANSLATORS: How far through the book the reader is, spoken by the three-finger tap; {} is a whole number
		let read = t("{} percent").replacingOccurrences(of: "{}", with: "\(percent)")
		let page = turnedTo?.unit == currentUnit ? turnedTo?.page : model.page(atPosition: position)
		guard let page, !model.pageLabels[page].isEmpty else { return read }
		return BookModel.pageName(model.pageLabels[page]) + ", " + read
	}

	func accessibilityScrollStatus(for scrollView: UIScrollView) -> String? {
		status()
	}

	/// Moves to the start of the next or previous page: the book's own pages when it has them, else the screen's.
	private func turnPage(forward: Bool) -> Bool {
		let target: Int?
		if model.pagePositions.isEmpty {
			target = bookView.visualPageStop(forward: forward)
		} else {
			let known = turnedTo?.unit == currentUnit ? turnedTo?.page : nil
			let turn = model.pageTurn(from: currentUnit, onPage: known, forward: forward)
			target = turn?.unit
			if let turn { turnedTo = turn }
		}
		guard let target else {
			// The same status again tells VoiceOver it is at the edge.
			UIAccessibility.post(notification: .pageScrolled, argument: status())
			return false
		}
		move(to: target, startingPage: true)
		UIAccessibility.post(notification: .pageScrolled, argument: status())
		return true
	}

	// MARK: Without VoiceOver

	@objc private func handleTap() {
		onMenu?()
	}

	@objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
		bookView.turnPage(forward: gesture.direction == .left)
		setCurrent(bookView.firstUnitOnPage)
	}
}
