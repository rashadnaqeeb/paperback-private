import SwiftUI

/// The in-book menu, opened by double-tapping any paragraph: Exit Book at the top, then Contents, Bookmarks,
/// Settings, and Book Info and Search.
struct BookMenuSheet: View {
	@Environment(AppViewModel.self) private var viewModel
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		TabView {
			tab { TocView() }
				// TRANSLATORS: Tab of the in-book menu holding the table of contents
				.tabItem { Label(t("Contents"), systemImage: "list.bullet") }
			tab { BookmarksView() }
				// TRANSLATORS: Tab of the in-book menu holding the book's bookmarks
				.tabItem { Label(t("Bookmarks"), systemImage: "bookmark") }
			tab { SettingsView() }
				// TRANSLATORS: Tab of the in-book menu holding the app's settings
				.tabItem { Label(t("Settings"), systemImage: "gear") }
			tab { BookInfoView() }
				// TRANSLATORS: Tab of the in-book menu with the book's title, author, chapter, percent read, and search
				.tabItem { Label(t("Info and Search"), systemImage: "info.circle") }
		}
	}

	/// A tab's screen with Exit Book first and a way back to the book.
	private func tab(@ViewBuilder _ content: () -> some View) -> some View {
		NavigationStack {
			content()
				.toolbar {
					ToolbarItem(placement: .topBarLeading) {
						// TRANSLATORS: In-book menu button that closes the book and returns to the list of books
						Button(t("Exit Book")) {
							dismiss()
							viewModel.closeBook()
						}
					}
					ToolbarItem(placement: .topBarTrailing) {
						// TRANSLATORS: In-book menu button that closes the menu and returns to the book
						Button(t("Done")) { dismiss() }
					}
				}
		}
	}
}
