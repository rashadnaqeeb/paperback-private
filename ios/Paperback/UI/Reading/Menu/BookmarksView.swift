import SwiftUI

/// The book's bookmarks: add one at the paragraph the menu was opened from, jump to one, rename or delete.
struct BookmarksView: View {
	@Environment(AppViewModel.self) private var viewModel
	@Environment(\.dismiss) private var dismiss
	@State private var bookmarks: [BookmarkFfi] = []
	@State private var renaming: BookmarkFfi?
	@State private var newName = ""

	var body: some View {
		List {
			Section {
				// TRANSLATORS: Button in the in-book menu that bookmarks the paragraph being read
				Button(t("Add Bookmark")) {
					let added = viewModel.addBookmark()
					reload()
					// TRANSLATORS: Spoken after a bookmark is added, or when the paragraph already had one
					UIAccessibility.post(notification: .announcement, argument: added ? t("Bookmark added") : t("Already bookmarked"))
				}
			}
			if !bookmarks.isEmpty {
				Section {
					ForEach(bookmarks, id: \.self) { bookmark in
						Button(viewModel.bookmarkLabel(bookmark)) {
							viewModel.reading.goToPosition(bookmark.start, announce: true)
							dismiss()
						}
						// TRANSLATORS: Action renaming a bookmark
						.accessibilityAction(named: t("Rename")) { startRenaming(bookmark) }
						// TRANSLATORS: Action deleting a bookmark
						.accessibilityAction(named: t("Delete")) { delete(bookmark) }
						.swipeActions {
							Button(t("Delete"), role: .destructive) { delete(bookmark) }
							Button(t("Rename")) { startRenaming(bookmark) }
						}
					}
				}
			}
		}
		// TRANSLATORS: Title of the in-book menu's bookmarks tab
		.navigationTitle(t("Bookmarks"))
		.navigationBarTitleDisplayMode(.inline)
		.onAppear(perform: reload)
		// TRANSLATORS: Title of the dialog renaming a bookmark
		// The bookmark comes in as the presented value: the presentation binding may already be cleared when Save runs.
		.alert(t("Rename Bookmark"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { bookmark in
			// TRANSLATORS: Placeholder of the field holding a bookmark's name
			TextField(t("Name"), text: $newName)
			// TRANSLATORS: Button saving a bookmark's new name
			Button(t("Save")) {
				viewModel.renameBookmark(bookmark, to: newName)
				reload()
			}
			Button(t("Cancel"), role: .cancel) {}
		}
	}

	private func reload() {
		bookmarks = viewModel.bookmarks()
	}

	private func startRenaming(_ bookmark: BookmarkFfi) {
		newName = viewModel.bookmarkLabel(bookmark)
		renaming = bookmark
	}

	private func delete(_ bookmark: BookmarkFfi) {
		viewModel.deleteBookmark(bookmark)
		reload()
	}
}
