import SwiftUI
import UniformTypeIdentifiers

struct BooksView: View {
	@Environment(AppViewModel.self) private var viewModel
	@Environment(\.dismiss) private var dismiss
	@State private var choosingFolder = false
	@State private var downloading: URL? = nil

	var body: some View {
		let library = viewModel.booksFolder
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
			if library.folderURL != nil {
				ToolbarItem(placement: .topBarTrailing) {
					// TRANSLATORS: Button on the Books screen that picks a different books folder
					Button(t("Change Folder")) { choosingFolder = true }
				}
			}
		}
		.fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
			guard case .success(let url) = result else { return }
			library.choose(url)
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
				let local = try await BooksFolder.download(book)
				viewModel.openDocument(url: local)
				if viewModel.activeTab?.url == local { dismiss() }
			} catch {
				viewModel.debugMessage = "Error downloading '\(book.lastPathComponent)':\n\(error)"
			}
		}
	}
}
