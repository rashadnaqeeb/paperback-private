import SwiftUI
import Combine
import UIKit

@MainActor
@Observable
final class AppViewModel {
	/// The one book being read, or nil while the library is showing.
	private(set) var book: OpenBook?

	var activeSession: DocumentSession? { book?.session }

	let navigation = NavigationRouter()

	let reading = ReadingController()

	let booksFolder = BooksFolder()

	var swipeUpMovesForward = true {
		didSet { configManager.setAppBool(key: "swipe_up_moves_forward", value: swipeUpMovesForward) }
	}
	/// Drops the player's previous and next buttons from the screen reader order. They
	/// duplicate the swipe up and down actions already on the play button, so hiding them makes
	/// the bar three stops instead of five. Off by default: the swipe is not discoverable on its
	/// own, so nobody should lose the buttons without having chosen to.
	var hidePrevNextButtons: Bool = false {
		didSet { configManager.setAppBool(key: "hide_prev_next_buttons", value: hidePrevNextButtons) }
	}

	let configManager = ConfigManagerFfi()
	@ObservationIgnored private var cancellables = Set<AnyCancellable>()

	init() {
		setPdfiumLibraryPath(path: Bundle.main.bundlePath + "/Frameworks/libpdfium.framework")
		_ = configManager.initialize(configPath: configFilePath())
		configManager.syncStartFfi(device: "iphone", store: ICloudSyncStore())
		swipeUpMovesForward = configManager.getAppBool(key: "swipe_up_moves_forward", defaultValue: true)
		hidePrevNextButtons = configManager.getAppBool(key: "hide_prev_next_buttons", defaultValue: false)
		reading.context = self
		let narration = RecordedNarration(config: configManager)
		narration.onClipChanged = { [weak self] position in
			// The recording is the authority on where the reader is while it plays, so the
			// position and the displayed text follow it rather than the other way round.
			guard let self else { return }
			self.reading.position = position
			self.reading.refreshSegmentForAudio()
			self.updatePosition(position)
		}
		narration.onPlayingChanged = { [weak self] _ in
			self?.reading.updateNowPlaying()
		}
		narration.onSeekLanded = { [weak self] elapsedMs in
			self?.reading.announceAudioSeekLanded(elapsedMs)
		}
		reading.narration = narration
		reading.start()
		NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
			.sink { [weak self] _ in
				self?.saveConfig()
			}
			.store(in: &cancellables)
		NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
			.sink { [weak self] _ in
				self?.watchForSyncedPosition()
			}
			.store(in: &cancellables)
		NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
			.sink { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.takeSyncedPosition()
				}
			}
			.store(in: &cancellables)
		NotificationCenter.default.publisher(for: .pbMagicTap)
			.sink { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.reading.togglePlayPause()
				}
			}
			.store(in: &cancellables)
		reading.updateNowPlaying()
		reopenLastBook()
	}

	var debugMessage: String? = nil

	/// The file name of the book open when the app last ran, cleared by Exit Book. Kept as a name
	/// inside the books folder rather than a path so it survives the folder being chosen again.
	private static let openBookKey = "pb_open_book"

	private func reopenLastBook() {
		guard let name = UserDefaults.standard.string(forKey: Self.openBookKey), let folder = booksFolder.folderURL else { return }
		let url = folder.appendingPathComponent(name)
		let placeholder = folder.appendingPathComponent(".\(name).icloud")
		// A book renamed or deleted since would otherwise put up an error at every launch.
		guard FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path) else {
			UserDefaults.standard.removeObject(forKey: Self.openBookKey)
			return
		}
		Task {
			guard let local = try? await BooksFolder.download(url), book == nil else { return }
			openBook(url: local)
			if book == nil { UserDefaults.standard.removeObject(forKey: Self.openBookKey) }
		}
	}

	/// Opens `url` in place of whatever book was open. The file's access comes from the books
	/// folder's security scope, which BooksFolder holds for the life of the app.
	func openBook(url: URL) {
		if book?.url == url { return }
		closeBook()
		let path = url.path(percentEncoded: false)
		do {
			let session = try DocumentSession.newFfi(
				filePath: path,
				password: configManager.getDocumentPassword(path: path),
				forcedExtension: "",
				renderTablesInline: false
			)
			_ = configManager.syncOpenFfi(path: path, session: session)
			let title = session.title().isEmpty ? url.deletingPathExtension().lastPathComponent : session.title()
			let opened = OpenBook(title: title, url: url, currentPosition: configManager.getDocumentPosition(path: path), session: session)
			book = opened
			booksFolder.markRead(url)
			UserDefaults.standard.set(url.lastPathComponent, forKey: Self.openBookKey)
			reading.loadSegment(for: opened)
			reading.updateNowPlaying()
			watchForSyncedPosition()
		} catch {
			debugMessage = "Error opening '\(url.lastPathComponent)':\n\(error)\n\nPath: \(path)"
		}
	}

	/// Saves where the reader got to and returns to the library. The position itself is already
	/// in the config: every move writes it there.
	func closeBook() {
		guard book != nil else { return }
		reading.narration?.detach()
		reading.onJump = nil
		reading.onRefocus = nil
		reading.cancelSleepTimer()
		reading.activeSearchQuery = nil
		saveConfig()
		UserDefaults.standard.removeObject(forKey: Self.openBookKey)
		book = nil
		reading.updateNowPlaying()
	}

	// MARK: Sync

	@ObservationIgnored private var pendingSave: Task<Void, Never>?
	/// The book, and the place in it, that a newer place from the Mac may still replace, and until when.
	@ObservationIgnored private var watching: (path: String, position: Int64, until: Date)?

	/// Writes the config, and with it this device's entry in the iCloud store.
	func saveConfig() {
		pendingSave?.cancel()
		configManager.flush()
	}

	/// Saves once the reader has stayed on one paragraph a few seconds, so the other device has the place even if this
	/// one never goes to the background.
	private func saveSoon() {
		pendingSave?.cancel()
		pendingSave = Task { [weak self] in
			try? await Task.sleep(for: .seconds(5))
			guard !Task.isCancelled else { return }
			self?.saveConfig()
		}
	}

	/// After a book opens or the app comes back to the front, takes where the Mac left the book: now, and whenever iCloud
	/// brings a change from it in the next two minutes, since it can take a while. Taking it moves the book as a jump, so
	/// the scrub returns to where this phone was. Once the reader has moved, nothing moves the book: that would be
	/// mid-page.
	private func watchForSyncedPosition() {
		guard let path = bookPath else {
			watching = nil
			return
		}
		watching = (path, reading.position, Date().addingTimeInterval(120))
		takeSyncedPosition()
	}

	private func takeSyncedPosition() {
		guard let watch = watching, watch.path == bookPath, watch.position == reading.position, Date() < watch.until else {
			watching = nil
			return
		}
		guard let move = configManager.syncPullFfi().first(where: { $0.path == watch.path }) else { return }
		watching = nil
		reading.goToPosition(move.position)
	}

	// MARK: Bookmarks and where the reader is

	private var bookPath: String? { book?.url.path(percentEncoded: false) }

	/// The open book's bookmarks in position order.
	func bookmarks() -> [BookmarkFfi] {
		guard let bookPath else { return [] }
		return configManager.getBookmarksFfi(path: bookPath)
	}

	/// Bookmarks the paragraph being read with an automatic label, never asking for one. Start and end are the same,
	/// which the desktop reads as the whole line. False when the paragraph already had a bookmark.
	@discardableResult
	func addBookmark() -> Bool {
		guard let bookPath else { return false }
		let position = reading.position
		let before = bookmarks().count
		configManager.addBookmarkFfi(path: bookPath, start: position, end: position, note: automaticLabel(at: position))
		saveConfig()
		return bookmarks().count > before
	}

	func renameBookmark(_ bookmark: BookmarkFfi, to name: String) {
		guard let bookPath else { return }
		configManager.updateBookmarkNoteFfi(path: bookPath, start: bookmark.start, end: bookmark.end, note: name.trimmingCharacters(in: .whitespaces))
		saveConfig()
	}

	func deleteBookmark(_ bookmark: BookmarkFfi) {
		guard let bookPath else { return }
		configManager.removeBookmarkFfi(path: bookPath, start: bookmark.start, end: bookmark.end)
		saveConfig()
	}

	/// A bookmark's name, or, for one made elsewhere without a note, the label it would have been given here.
	func bookmarkLabel(_ bookmark: BookmarkFfi) -> String {
		bookmark.note.isEmpty ? automaticLabel(at: bookmark.start) : bookmark.note
	}

	/// The chapter and the paragraph's opening words.
	private func automaticLabel(at position: Int64) -> String {
		let words = (activeSession?.getLineText(position: position) ?? "").split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
		guard let chapter = chapterTitle(at: position), chapter != words else { return words }
		return words.isEmpty ? chapter : "\(chapter): \(words)"
	}

	/// The table of contents entry the position is in.
	func chapterTitle(at position: Int64) -> String? {
		activeSession?.getToc().last { $0.position <= position }?.title
	}

	var percentRead: Int {
		Int(activeSession?.getStatusInfo(position: reading.position).percentage ?? 0)
	}

	private func updatePosition(_ position: Int64) {
		guard book != nil else { return }
		book?.currentPosition = position
		if let path = book?.url.path(percentEncoded: false) {
			configManager.setDocumentPosition(path: path, position: position)
			saveSoon()
		}
	}
}

extension AppViewModel: ReadingContext {
	var activeTitle: String? { book?.title }

	func persistPosition(_ position: Int64) {
		updatePosition(position)
	}
}

// What the previous/next controls move by. Ordinarily a structural unit; while a Find query is
// active, Find joins the list and steps between that query's matches instead.
enum NavUnit: Hashable {
	case segment(SegmentTypeFfi)
	/// An amount of elapsed recording to skip, for a book with its own narration. Stepping by
	/// paragraph means nothing in a bundle of audio files with no real text to walk.
	case time(seconds: Int)
	case find

	var name: String {
		switch self {
		case .segment(let type): return segmentTypeName(type)
		case .time(let seconds): return seekAmountName(seconds)
		// TRANSLATORS: Name of the "Find" navigation unit, which moves between search matches
		case .find: return t("Find")
		}
	}
}

/// Renders a duration the way the reading bar reports one: minutes and seconds, with hours only
/// once there are any.
func formatDuration(_ ms: Int64) -> String {
	let totalSeconds = (max(ms, 0) + 500) / 1000
	let hours = totalSeconds / 3600
	let minutes = (totalSeconds % 3600) / 60
	let seconds = totalSeconds % 60
	return hours > 0
		? String(format: "%d:%02d:%02d", hours, minutes, seconds)
		: String(format: "%d:%02d", minutes, seconds)
}

/// The seek amounts a recorded book offers, matching the presets desktop shows in its Options.
let audioSeekAmountsSeconds = [5, 10, 30, 60, 120]

/// Matches the labels desktop shows for the same presets in its Options dialog.
func seekAmountName(_ seconds: Int) -> String {
	switch seconds {
	// TRANSLATORS: Audio seek amount, shown as a navigation unit in the read-aloud bar
	case 5: return t("5 seconds")
	// TRANSLATORS: Audio seek amount, shown as a navigation unit in the read-aloud bar
	case 10: return t("10 seconds")
	// TRANSLATORS: Audio seek amount, shown as a navigation unit in the read-aloud bar
	case 30: return t("30 seconds")
	// TRANSLATORS: Audio seek amount, shown as a navigation unit in the read-aloud bar
	case 60: return t("1 minute")
	// TRANSLATORS: Audio seek amount, shown as a navigation unit in the read-aloud bar
	case 120: return t("2 minutes")
	default: return "\(seconds)"
	}
}

func segmentTypeName(_ type: SegmentTypeFfi) -> String {
	switch type {
	// TRANSLATORS: Name of the "paragraph" reading/navigation unit
	case .paragraph: return t("Paragraph")
	// TRANSLATORS: Name of the "line" reading/navigation unit
	case .line: return t("Line")
	// TRANSLATORS: Name of the "heading" reading/navigation unit
	case .heading: return t("Heading")
	// TRANSLATORS: Name of the "link" reading/navigation unit
	case .link: return t("Link")
	// TRANSLATORS: Name of the "section" reading/navigation unit
	case .section: return t("Section")
	// TRANSLATORS: Name of the "page" reading/navigation unit
	case .page: return t("Page")
	// TRANSLATORS: Name of the "list" reading/navigation unit
	case .list: return t("List")
	// TRANSLATORS: Name of the "list item" reading/navigation unit
	case .listItem: return t("List Item")
	// TRANSLATORS: Name of the "table" reading/navigation unit
	case .table: return t("Table")
	// TRANSLATORS: Name of the "separator" reading/navigation unit
	case .separator: return t("Separator")
	// TRANSLATORS: Name of the "image" reading/navigation unit
	case .image: return t("Image")
	// TRANSLATORS: Name of the "figure" reading/navigation unit
	case .figure: return t("Figure")
	// TRANSLATORS: Name of the "formula" reading/navigation unit
	case .formula: return t("Formula")
	}
}

/// A whole phrase per unit, because many languages inflect "previous"/"next" to agree with the noun (#1033).
func previousUnitLabel(_ type: SegmentTypeFfi) -> String {
	switch type {
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by paragraph
	case .paragraph: return t("Previous Paragraph")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by line
	case .line: return t("Previous Line")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by heading
	case .heading: return t("Previous Heading")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by link
	case .link: return t("Previous Link")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by section
	case .section: return t("Previous Section")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by page
	case .page: return t("Previous Page")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by list
	case .list: return t("Previous List")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by list item
	case .listItem: return t("Previous List Item")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by table
	case .table: return t("Previous Table")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by separator
	case .separator: return t("Previous Separator")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by image
	case .image: return t("Previous Image")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by figure
	case .figure: return t("Previous Figure")
	// TRANSLATORS: Accessibility label for the read-aloud bar's previous button when navigating by formula
	case .formula: return t("Previous Formula")
	}
}

/// A whole phrase per unit, because many languages inflect "previous"/"next" to agree with the noun (#1033).
func nextUnitLabel(_ type: SegmentTypeFfi) -> String {
	switch type {
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by paragraph
	case .paragraph: return t("Next Paragraph")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by line
	case .line: return t("Next Line")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by heading
	case .heading: return t("Next Heading")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by link
	case .link: return t("Next Link")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by section
	case .section: return t("Next Section")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by page
	case .page: return t("Next Page")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by list
	case .list: return t("Next List")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by list item
	case .listItem: return t("Next List Item")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by table
	case .table: return t("Next Table")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by separator
	case .separator: return t("Next Separator")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by image
	case .image: return t("Next Image")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by figure
	case .figure: return t("Next Figure")
	// TRANSLATORS: Accessibility label for the read-aloud bar's next button when navigating by formula
	case .formula: return t("Next Formula")
	}
}

enum GoToMode {
	case line, page, percent
}

struct SearchOptions: Equatable {
	var matchCase: Bool = false
	var wholeWord: Bool = false
	var regex: Bool = false
}

private func configFilePath() -> String {
	let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
	let dir = support.appendingPathComponent("dev.paperback.mobile", isDirectory: true)
	try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	return dir.appendingPathComponent("config.toml").path
}
