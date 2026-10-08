import UIKit

/// An item in the in-book menu.
struct ReadingMenuItem {
	let title: String
	let action: () -> Void
}

/// Hosts the reading surface: lands VoiceOver on the saved paragraph, saves the position as focus moves, opens the
/// menu on double-tap, and turns pages by swipe for reading without VoiceOver.
@MainActor
final class ReadingViewController: UIViewController {
	private let bookView: BookView
	private var currentIndex: Int

	/// The book position of the paragraph the reader is on, whenever it changes.
	var onPositionChange: ((Int64) -> Void)?
	var onExit: (() -> Void)?
	var menuTitle = ""
	var menuItems: () -> [ReadingMenuItem] = { [] }

	/// VoiceOver focuses the first element by itself when the screen appears, before the restore lands. Until focus
	/// reaches the restore target, those stray focus events must not be saved, or they overwrite the real position with
	/// the book's start. The restore is posted again a few times, then wherever the reader actually is counts.
	private var restoreTarget = 0
	private var hasRestored = false
	private var restoreAttemptsLeft = 3

	init(text: BookText, startIndex: Int) {
		bookView = BookView(text: text)
		currentIndex = startIndex
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError("not used") }

	override func loadView() {
		view = bookView
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		bookView.onFocusChange = { [weak self] index in
			self?.handleFocus(at: index)
		}
		bookView.onActivate = { [weak self] in
			self?.showMenu()
		}
		bookView.onEscape = { [weak self] in
			self?.onExit?()
		}
		let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
		view.addGestureRecognizer(tap)
		for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
			let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
			swipe.direction = direction
			view.addGestureRecognizer(swipe)
		}
		// Centered on the saved position before VoiceOver's first query, so the restored paragraph owns the screen
		// from the start.
		bookView.reveal(currentIndex)
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		// Also runs on returning from the table of contents or Find, which is how a jump made there lands.
		restoreTarget = currentIndex
		hasRestored = false
		restoreAttemptsLeft = 3
		postRestoreFocus()
	}

	private func postRestoreFocus() {
		guard let element = bookView.element(at: restoreTarget) else { return }
		UIAccessibility.post(notification: .screenChanged, argument: element)
	}

	private func handleFocus(at index: Int) {
		if !hasRestored {
			if index == restoreTarget || restoreAttemptsLeft == 0 {
				hasRestored = true
			} else {
				restoreAttemptsLeft -= 1
				postRestoreFocus()
				return
			}
		}
		setCurrent(index)
	}

	private func setCurrent(_ index: Int) {
		guard index != currentIndex else { return }
		currentIndex = index
		onPositionChange?(bookView.text.position(ofElement: index))
	}

	/// Moves to a paragraph the app chose (a table of contents entry, a Find match), with VoiceOver focus following
	/// when the reading screen is showing.
	func go(to index: Int) {
		bookView.reveal(index)
		setCurrent(bookView.focusedIndex)
		restoreTarget = bookView.focusedIndex
		guard view.window != nil, let element = bookView.element(at: restoreTarget) else { return }
		UIAccessibility.post(notification: .layoutChanged, argument: element)
	}

	@objc private func handleTap() {
		showMenu()
	}

	@objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
		bookView.turnPage(forward: gesture.direction == .left)
		setCurrent(bookView.firstIndexOnPage)
	}

	private func showMenu() {
		let menu = UIAlertController(title: menuTitle, message: nil, preferredStyle: .actionSheet)
		for item in menuItems() {
			menu.addAction(UIAlertAction(title: item.title, style: .default) { _ in item.action() })
		}
		// TRANSLATORS: Button that closes the in-book menu and returns to the book
		menu.addAction(UIAlertAction(title: t("Cancel"), style: .cancel) { [weak self] _ in
			self?.returnFocusToBook()
		})
		menu.popoverPresentationController?.sourceView = view
		menu.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
		present(menu, animated: true)
	}

	private func returnFocusToBook() {
		guard let element = bookView.element(at: currentIndex) else { return }
		UIAccessibility.post(notification: .layoutChanged, argument: element)
	}
}
