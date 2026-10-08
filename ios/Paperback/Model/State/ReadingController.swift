import SwiftUI
import UIKit
import MediaPlayer

// The book state reading needs but does not own: which book is open, and where its reading
// position gets stored.
@MainActor
protocol ReadingContext: AnyObject {
	var activeSession: DocumentSession? { get }
	var activeTitle: String? { get }
	func persistPosition(_ position: Int64)
}

// Everything about reading the open book: the reading position, jumps to a place in it, search,
// and for a book with recorded narration, playback, the player's previous and next, the sleep
// timer, and the Now Playing and remote command surface.
@MainActor
@Observable
final class ReadingController {
	@ObservationIgnored weak var context: ReadingContext?

	private var activeSession: DocumentSession? { context?.activeSession }

	// Called once the context is set, since the remote commands need it.
	func start() {
		setupRemoteCommands()
	}

	/// A recorded book's own narration. Set by AppViewModel, which owns the config it persists
	/// playback position to.
	var narration: RecordedNarration?
	/// Whether the open book carries its own recording, which makes it a book for the player
	/// rather than the reading screen.
	var hasAudio: Bool { activeSession?.hasAudioFfi() == true }
	/// A book whose text is only there to anchor the audio has nothing to step through but the
	/// recording itself.
	var isAudioOnly: Bool { activeSession?.isAudioOnlyFfi() == true }
	var isPlaying: Bool { hasAudio && narration?.isPlaying == true }
	var position: Int64 = 0
	var currentSegmentText: String = ""
	/// Set by the reading screen while it shows, to move it to a position the reader jumped to.
	@ObservationIgnored var onJump: ((Int64) -> Void)?
	/// Set by the reading screen while it shows, to put VoiceOver back on the reader's paragraph after the menu closes.
	@ObservationIgnored var onRefocus: (() -> Void)?
	var currentNavUnit: NavUnit = .segment(.section)
	// The structural unit the FFI is asked for. Find isn't one, so it reads as paragraph: that's
	// what a match's surrounding context is spoken as.
	var currentSegmentType: SegmentTypeFfi {
		if case .segment(let type) = currentNavUnit { return type }
		return .paragraph
	}
	// The units the player's previous and next can move by. The core decides which structure a
	// book offers; Find only joins the list once there's a query to step through.
	var availableNavUnits: [NavUnit] {
		guard hasAudio else { return [] }
		var segments = (activeSession?.getSupportedSegmentTypesFfi() ?? []).map { NavUnit.segment($0) }
		// A book that is only a bundle of narration files has no prose to step through, so each
		// underlying audio file being its own section is all the structure there is.
		if isAudioOnly { segments = segments.filter { $0 == .segment(.section) } }
		segments = audioSeekAmountsSeconds.map { NavUnit.time(seconds: $0) } + segments
		return activeSearchQuery == nil ? segments : segments + [.find]
	}
	// Keeps the selected unit on something the newly opened book supports.
	func ensureNavUnitSupported() {
		let units = availableNavUnits
		guard !units.isEmpty, !units.contains(currentNavUnit) else { return }
		currentNavUnit = units[0]
	}

	var activeSearchQuery: String? = nil
	var searchOptions = SearchOptions()

	var sleepTimerRemaining: Int? = nil
	private var sleepTimerTask: Task<Void, Never>? = nil

	func togglePlayPause() {
		guard hasAudio, let narration else { return }
		if narration.isPlaying { narration.pause() } else { narration.play() }
		updateNowPlaying()
	}

	/// Moves the player forward by the chosen unit, reporting whether there was anywhere to go.
	@discardableResult
	func moveNext() -> Bool {
		move(forward: true)
	}

	@discardableResult
	func movePrevious() -> Bool {
		move(forward: false)
	}

	private func move(forward: Bool) -> Bool {
		guard hasAudio, let narration else { return false }
		switch currentNavUnit {
		case .time(let seconds):
			let deltaMs = Int64(seconds) * 1000
			narration.seekRelativeMs(forward ? deltaMs : -deltaMs)
			return true
		case .find:
			// Once Find is the chosen unit, previous and next are always about matches, even with
			// none left: there is nothing else for them to fall back to.
			guard activeSearchQuery != nil else { return true }
			guard let match = findMatch(forward: forward, skipCurrent: true) else {
				// TRANSLATORS: Announced when stepping to the next/previous Find match runs off the end of the document
				announce(t("No more matches."))
				return true
			}
			jump(to: match, announce: true)
			return true
		case .segment(let type):
			return navigateRecordedSegment(type, direction: forward ? .next : .previous)
		}
	}

	private func announceNavigationCue(_ text: String) {
		let words = text.split(whereSeparator: \.isWhitespace)
		announce(words.prefix(5).joined(separator: " "))
	}

	private func announce(_ text: String) {
		// Delay so SwiftUI's layout-changed accessibility notification fires first;
		// otherwise it interrupts the announcement when triggered by a button tap.
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(150))
			UIAccessibility.post(notification: .announcement, argument: text)
		}
	}

	func changeNavUnit(_ unit: NavUnit) {
		currentNavUnit = unit
	}

	/// Structural audio navigation uses the core's markers (chapters, files, or DAISY
	/// sections), while the recording retains its current play/pause state.
	@discardableResult
	private func navigateRecordedSegment(_ type: SegmentTypeFfi, direction: SegmentDirectionFfi) -> Bool {
		guard let session = activeSession, let narration else { return false }
		let seg = session.getTextSegment(position: position, segmentType: type, direction: direction)
		guard seg.found, seg.startPos != position else { return false }
		guard narration.seekToPosition(seg.startPos) else { return false }
		position = seg.startPos
		currentSegmentText = seg.text
		context?.persistPosition(seg.startPos)
		// Section titles can exceed the five-word cue used for ordinary text navigation.
		let title = seg.text.isEmpty ? sectionTitle(at: seg.startPos) : seg.text
		if !title.isEmpty { announce(title) }
		return true
	}

	func setSleepTimer(seconds: Int) {
		cancelSleepTimer()
		sleepTimerRemaining = seconds
		sleepTimerTask = Task {
			while true {
				try? await Task.sleep(for: .seconds(1))
				if Task.isCancelled { return }
				guard let r = sleepTimerRemaining, r > 0 else {
					narration?.pause()
					updateNowPlaying()
					sleepTimerRemaining = nil
					return
				}
				sleepTimerRemaining = r - 1
			}
		}
	}

	func cancelSleepTimer() {
		sleepTimerTask?.cancel()
		sleepTimerTask = nil
		sleepTimerRemaining = nil
	}

	// Starts (or re-runs) a search and immediately jumps to the first match in the given
	// direction: there's no separate "start search" step. For a book in the player, Find then
	// becomes the navigation unit, so previous and next walk the rest of the matches without
	// reopening the Find screen.
	func startSearch(query: String, options: SearchOptions, forward: Bool) {
		// A fresh query searches from the reading position itself, so a match already under the
		// cursor counts. Re-running the query that is already active is the user asking for the
		// next one, so it steps past that match instead of landing on it again.
		let repeated = query == activeSearchQuery && options == searchOptions
		activeSearchQuery = query
		searchOptions = options
		if hasAudio { currentNavUnit = .find }
		// The Find screen stays up and VoiceOver focus stays in it, so the announcement is the
		// only sign the reading position moved at all.
		if let match = findMatch(forward: forward, skipCurrent: repeated) {
			jump(to: match, announce: false)
			announceNavigationCue(currentSegmentText)
		} else if repeated {
			// TRANSLATORS: Announced when stepping to the next/previous Find match runs off the end of the document
			announce(t("No more matches."))
		} else {
			// TRANSLATORS: Announced when a Find query matches nothing anywhere in the document
			announce(t("No matches."))
		}
	}

	// Where the next match of the active query is, if there is one. Forward search is inclusive
	// of the start position, so stepping off a match we're sitting on has to nudge past it;
	// backward search is already exclusive and needs no such adjustment.
	private func findMatch(forward: Bool, skipCurrent: Bool) -> Int64? {
		guard let session = activeSession, let query = activeSearchQuery else { return nil }
		let start = forward && skipCurrent ? position + 1 : position
		let result = session.searchFfi(
			query: query,
			startPosition: start,
			options: SearchOptionsFfi(
				matchCase: searchOptions.matchCase,
				wholeWord: searchOptions.wholeWord,
				regex: searchOptions.regex,
				forward: forward
			)
		)
		return result.found ? result.position : nil
	}

	func goToLine(_ line: Int64) {
		guard let session = activeSession else { return }
		jump(to: session.positionFromLine(line: line), announce: false)
	}

	/// `announce` is for a jump the reader asked for, as opposed to restoring a saved position
	/// when a book opens, which nobody wants read out.
	func goToPosition(_ position: Int64, announce shouldAnnounce: Bool = false) {
		jump(to: position, announce: shouldAnnounce)
	}

	func goToPage(_ page: Int32, announce shouldAnnounce: Bool = false) {
		guard let session = activeSession else { return }
		jump(to: session.pageOffset(page: page), announce: shouldAnnounce)
	}

	/// Seeks the recording to `percent` of its running time, reporting whether it applied.
	///
	/// False for a book with no recording, and for one whose file lengths are not all known, so
	/// the caller maps the percentage through the text instead. A percentage through the text of
	/// an audiobook counts blank lines, one per file, so it treats a two minute file and an hour
	/// long one as equal shares of the book.
	///
	/// The reading position follows on its own: the player reports the clip it lands in.
	@discardableResult
	func seekAudioToPercent(_ percent: Int32) -> Bool {
		guard hasAudio, let session = activeSession, let narration else { return false }
		let targetMs = session.audioElapsedForPercentFfi(percent: percent)
		guard targetMs >= 0 else { return false }
		return narration.seekToMs(targetMs)
	}

	func goToPercent(_ percent: Int32, announce shouldAnnounce: Bool = false) {
		guard let session = activeSession else { return }
		jump(to: session.positionFromPercent(percent: percent), announce: shouldAnnounce)
	}

	// Lands the reader somewhere else in the book. The recording moves with it, or the reader
	// would go on listening to where they used to be; in the player, nothing else reports the
	// move, so a jump the reader asked for says where they arrived. The reading screen moves
	// VoiceOver to the paragraph instead, which reads it.
	private func jump(to newPosition: Int64, announce shouldAnnounce: Bool) {
		position = newPosition
		context?.persistPosition(newPosition)
		refreshCurrentSegment()
		if hasAudio, let narration {
			narration.seekToPosition(newPosition)
			if shouldAnnounce { announceNavigationCue(currentSegmentText) }
		} else {
			onJump?(newPosition)
		}
	}

	/// The reading screen's report of the paragraph the reader is on.
	func readerMoved(to newPosition: Int64) {
		position = newPosition
		context?.persistPosition(newPosition)
	}

	func loadSegment(for book: OpenBook) {
		guard let session = book.session else { return }
		narration?.attach(to: book)
		ensureNavUnitSupported()
		position = book.currentPosition
		refreshCurrentSegment()
	}

	/// The file whose name was last announced after a seek, so a seek staying inside the same
	/// file doesn't repeat it.
	private var lastAnnouncedAudioSource: Int32?

	/// Keeps the displayed text in step with the recording.
	///
	/// An audio-only book's buffer is one placeholder space per file with no newlines anywhere,
	/// so asking for the paragraph enclosing a position collapses to the whole buffer and
	/// reports it as starting at 0. Deriving the label from that would pin it to the first
	/// file's name for the life of the book, however far playback had moved; the section (that
	/// is, the file) holding the current position is the only label there is.
	func refreshSegmentForAudio() {
		if isAudioOnly {
			currentSegmentText = sectionTitle(at: position)
			return
		}
		refreshCurrentSegment()
	}

	/// Speaks where a relative seek landed. An audiobook that is a bundle of narration files has
	/// no meaningful document-wide elapsed time (its clips carry placeholder durations), so its
	/// position reads as an offset into the file now playing, named whenever the file changes.
	func announceAudioSeekLanded(_ elapsedMs: Int64) {
		guard let session = activeSession else { return }
		let cursor = session.audioCursorAtElapsedFfi(elapsedMs: elapsedMs)
		guard cursor.found else { return }
		let clip = session.audioClipFfi(index: cursor.clipIndex)
		guard clip.found else { return }
		let time = formatDuration(isAudioOnly ? cursor.seekMs : elapsedMs)
		let fileChanged = lastAnnouncedAudioSource != clip.source
		lastAnnouncedAudioSource = clip.source
		let title = sectionTitle(at: clip.start)
		announce(fileChanged && !title.isEmpty ? "\(title), \(time)" : time)
	}

	/// The last table-of-contents entry at or before `position`, which for a recorded book names
	/// the file now playing.
	private func sectionTitle(at position: Int64) -> String {
		guard let session = activeSession else { return "" }
		return session.getToc().last { $0.position <= position }?.title ?? ""
	}

	private func refreshCurrentSegment() {
		guard let session = activeSession else { return }
		let seg = session.getTextSegment(
			position: position,
			segmentType: hasAudio ? currentSegmentType : .paragraph,
			direction: .current
		)
		currentSegmentText = seg.text
	}

	private func setupRemoteCommands() {
		let center = MPRemoteCommandCenter.shared()
		center.playCommand.addTarget { [weak self] _ in
			guard let self, hasAudio else { return .commandFailed }
			narration?.play()
			updateNowPlaying()
			return .success
		}
		center.pauseCommand.addTarget { [weak self] _ in
			guard let self, hasAudio else { return .commandFailed }
			narration?.pause()
			updateNowPlaying()
			return .success
		}
		center.togglePlayPauseCommand.addTarget { [weak self] _ in
			guard let self, hasAudio else { return .commandFailed }
			togglePlayPause()
			return .success
		}
		center.nextTrackCommand.addTarget { [weak self] _ in
			guard let self, hasAudio else { return .commandFailed }
			moveNext()
			updateNowPlaying()
			return .success
		}
		center.previousTrackCommand.addTarget { [weak self] _ in
			guard let self, hasAudio else { return .commandFailed }
			movePrevious()
			updateNowPlaying()
			return .success
		}
		center.stopCommand.addTarget { [weak self] _ in
			guard let self, hasAudio else { return .commandFailed }
			narration?.pause()
			updateNowPlaying()
			return .success
		}
		// Disable commands that don't apply to a book reader
		center.skipForwardCommand.isEnabled = false
		center.skipBackwardCommand.isEnabled = false
		center.seekForwardCommand.isEnabled = false
		center.seekBackwardCommand.isEnabled = false
		center.changePlaybackRateCommand.isEnabled = false
	}

	/// Only a book with its own recording has anything to show on the lock screen.
	func updateNowPlaying() {
		guard hasAudio else {
			MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
			return
		}
		var info: [String: Any] = [
			MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
			MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
			MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
		]
		if let title = context?.activeTitle {
			info[MPMediaItemPropertyTitle] = title
		}
		info[MPMediaItemPropertyArtist] = "Paperback"
		MPNowPlayingInfoCenter.default().nowPlayingInfo = info
	}
}
