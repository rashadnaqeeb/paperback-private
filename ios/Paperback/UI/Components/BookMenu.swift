import SwiftUI

/// The open book's menu. Stands in until the FlickRead in-book menu replaces it.
struct BookMenu: View {
	@Environment(AppViewModel.self) private var viewModel

	var body: some View {
		Menu {
			Button { viewModel.navigation.showToc = true } label: {
				// TRANSLATORS: Menu item to open the document's table of contents
				Label(t("Table of Contents"), systemImage: "list.bullet")
			}
			Button { viewModel.navigation.showElements = true } label: {
				// TRANSLATORS: Menu item to open the list of headings and links found in the document
				Label(t("Elements"), systemImage: "list.dash")
			}
			Divider()
			Button { viewModel.navigation.showFind = true } label: {
				// TRANSLATORS: Menu item to open find-in-document search
				Label(t("Find"), systemImage: "magnifyingglass")
			}
			Button { viewModel.navigation.showGoTo = true } label: {
				// TRANSLATORS: Menu item to jump to a specific page, line, or percentage in the document
				Label(t("Go To..."), systemImage: "arrow.right.circle")
			}
			Divider()
			Button { viewModel.navigation.showDocumentInfo = true } label: {
				// TRANSLATORS: Menu item to show document metadata (title, author, format, etc.)
				Label(t("Document Info"), systemImage: "info.circle")
			}
			if viewModel.reading.hasAudio {
				Button { viewModel.navigation.showSleepTimer = true } label: {
					// TRANSLATORS: Menu item to open the sleep timer; the "(active)" variant is shown while a timer is currently counting down
					let title: String = viewModel.reading.sleepTimerRemaining != nil ? t("Sleep Timer (active)") : t("Sleep Timer")
					Label(title, systemImage: "timer")
				}
			}
			Button { viewModel.navigation.showSettings = true } label: {
				// TRANSLATORS: Menu item to open the app's settings
				Label(t("Settings"), systemImage: "gear")
			}
		} label: {
			Image(systemName: "ellipsis.circle")
		}
		// TRANSLATORS: VoiceOver accessibility label for the "..." button that opens this document actions menu
		.accessibilityLabel(t("More options"))
	}
}
