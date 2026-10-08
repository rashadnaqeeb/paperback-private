import Foundation

// Which screen or dialog the reader is showing. This lives outside the views because the
// VoiceOver custom actions on BookMenu need something to set, and per-view @State would not
// reach.
@MainActor
@Observable
final class NavigationRouter {
	var showToc = false
	var showFind = false
	var showGoTo = false
	var goToInitialMode: GoToMode = .line
	var showSettings = false
	var showDocumentInfo = false
	var showSleepTimer = false
	var showElements = false
}
