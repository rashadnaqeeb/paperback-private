import SwiftUI
import UniformTypeIdentifiers

/// The home screen: the books folder's books. Opening one pushes the reader; Exit Book comes back here.
struct BooksView: View {
	@Environment(AppViewModel.self) private var viewModel
	@State private var choosingFolder = false
	@State private var showingSettings = false
	@State private var downloading: URL? = nil

	var body: some View {
		@Bindable var library = viewModel.booksFolder
		Group {
			if library.folderURL == nil {
				ContentUnavailableView {
					// TRANSLATORS: Title of the Books screen before a books folder has been chosen
					Label(t("No Books Folder"), systemImage: "books.vertical")
				} description: {
					// TRANSLATORS: Explanation on the Books screen before a books folder has been chosen
					Text(t("Choose the folder your books are in, such as a books folder in iCloud Drive. Paperback lists it from then on."))
				} actions: {
					// TRANSLATORS: Button that opens the folder picker to choose where books are kept
					Button(t("Choose Books Folder")) { choosingFolder = true }
				}
			} else if library.books.isEmpty {
				ContentUnavailableView(
					// TRANSLATORS: Title of the Books screen when the chosen books folder holds no books
					t("No Books"),
					systemImage: "books.vertical",
					// TRANSLATORS: Description under the "No Books" title on the Books screen
					description: Text(t("The books folder is empty."))
				)
			} else {
				List(library.books, id: \.self) { book in
					Button { open(book) } label: {
						HStack {
							Text(BooksFolder.title(of: book))
							Spacer()
							if downloading == book { ProgressView() }
						}
					}
					.disabled(downloading != nil)
				}
				.refreshable { library.refresh() }
			}
		}
		// TRANSLATORS: Navigation bar title of the screen listing the books in the books folder
		.navigationTitle(t("Books"))
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItemGroup(placement: .topBarTrailing) {
				if library.folderURL != nil {
					Menu {
						// TRANSLATORS: Label of the choice of order for the list of books
						Picker(t("Sort"), selection: $library.sort) {
							// TRANSLATORS: Sort order listing books alphabetically by title
							Text(t("Title")).tag(BookSort.title)
							// TRANSLATORS: Sort order listing the most recently opened books first
							Text(t("Recently Read")).tag(BookSort.recent)
						}
					} label: {
						// TRANSLATORS: Button that opens the choice of order for the list of books
						Label(t("Sort"), systemImage: "arrow.up.arrow.down")
					}
				}
				Button { showingSettings = true } label: {
					// TRANSLATORS: Button that opens the app's settings
					Label(t("Settings"), systemImage: "gear")
				}
			}
		}
		.fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
			guard case .success(let url) = result else { return }
			library.choose(url)
		}
		.navigationDestination(isPresented: $showingSettings) {
			SettingsView()
		}
		.navigationDestination(isPresented: Binding(
			get: { viewModel.book != nil },
			set: { if !$0 { viewModel.closeBook() } }
		)) {
			ReaderView()
		}
		// TRANSLATORS: Title of the alert shown when a document fails to open
		.alert(t("Open Error"), isPresented: Binding(
			get: { viewModel.debugMessage != nil },
			set: { if !$0 { viewModel.debugMessage = nil } }
		)) {
			// TRANSLATORS: Button dismissing the document-open-error alert
			Button(t("OK")) { viewModel.debugMessage = nil }
		} message: {
			Text(viewModel.debugMessage ?? "")
		}
		.onAppear { library.refresh() }
		.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
			library.refresh()
		}
	}

	private func open(_ book: URL) {
		downloading = book
		// TRANSLATORS: Spoken while a book is fetched from iCloud before it opens
		UIAccessibility.post(notification: .announcement, argument: t("Downloading"))
		Task {
			defer { downloading = nil }
			do {
				viewModel.openBook(url: try await BooksFolder.download(book))
			} catch {
				viewModel.debugMessage = "Error downloading '\(book.lastPathComponent)':\n\(error)"
			}
		}
	}
}
