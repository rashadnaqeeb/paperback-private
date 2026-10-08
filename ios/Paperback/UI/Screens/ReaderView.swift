import SwiftUI

/// The open book: the player for a book with recorded narration, the text for any other.
struct ReaderView: View {
	@Environment(AppViewModel.self) private var viewModel

	var body: some View {
		@Bindable var navigation = viewModel.navigation
		return mainContent
			.navigationTitle(viewModel.book?.title ?? "")
			.navigationBarTitleDisplayMode(.inline)
			.navigationBarBackButtonHidden(true)
			// The reading screen is the whole book with nothing else in the way; its menu opens on a double-tap.
			.toolbar(viewModel.reading.hasAudio ? .visible : .hidden, for: .navigationBar)
			.toolbar { readerToolbar }
			.safeAreaInset(edge: .bottom) { bottomBar }
			.navigationDestination(isPresented: $navigation.showToc) {
				TocView()
			}
			.navigationDestination(isPresented: $navigation.showFind) {
				FindView()
			}
			.sheet(isPresented: $navigation.showGoTo) {
				GoToSheet().environment(viewModel)
			}
			.navigationDestination(isPresented: $navigation.showSettings) {
				SettingsView()
			}
			.sheet(isPresented: $navigation.showDocumentInfo) {
				DocumentInfoSheet().environment(viewModel)
			}
			.navigationDestination(isPresented: $navigation.showSleepTimer) {
				SleepTimerView()
			}
			.navigationDestination(isPresented: $navigation.showElements) {
				ElementsView()
			}
			// TRANSLATORS: Title of the in-book menu, opened by double-tapping a paragraph
			.confirmationDialog(viewModel.book?.title ?? t("Menu"), isPresented: $navigation.showBookMenu, titleVisibility: .visible) {
				// TRANSLATORS: In-book menu item that closes the book and returns to the list of books
				Button(t("Exit Book")) { viewModel.closeBook() }
				// TRANSLATORS: Menu item to open the document's table of contents
				Button(t("Table of Contents")) { navigation.showToc = true }
				// TRANSLATORS: Menu item to open find-in-document search
				Button(t("Find")) { navigation.showFind = true }
				// TRANSLATORS: Menu item to jump to a specific page, line, or percentage in the document
				Button(t("Go To...")) { navigation.showGoTo = true }
				// TRANSLATORS: Menu item to show document metadata (title, author, format, etc.)
				Button(t("Document Info")) { navigation.showDocumentInfo = true }
				// TRANSLATORS: Menu item to open the app's settings
				Button(t("Settings")) { navigation.showSettings = true }
			}
	}

	@ViewBuilder
	private var mainContent: some View {
		if let session = viewModel.book?.session {
			if viewModel.reading.hasAudio {
				PlayerView()
			} else {
				ReadingScreen(viewModel: viewModel, session: session)
					.ignoresSafeArea()
					.id(viewModel.book?.url)
			}
		}
	}

	@ViewBuilder
	private var bottomBar: some View {
		if viewModel.reading.hasAudio {
			if #available(iOS 26, *) {
				// Floats as a Liquid Glass pill inset from the edges, matching Safari's bottom
				// toolbar, instead of a flat bar spanning the full width.
				PlayerControlBar()
					.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
					.padding(.horizontal, 12)
					.padding(.bottom, 8)
			} else {
				PlayerControlBar()
					.background {
						Rectangle()
							.fill(.bar)
							.ignoresSafeArea(edges: .bottom)
					}
			}
		}
	}

	@ToolbarContentBuilder
	private var readerToolbar: some ToolbarContent {
		ToolbarItem(placement: .topBarLeading) {
			// TRANSLATORS: Button that closes the open book and returns to the list of books
			Button(t("Exit Book")) { viewModel.closeBook() }
		}
		ToolbarItem(placement: .topBarTrailing) {
			BookMenu()
		}
	}
}
