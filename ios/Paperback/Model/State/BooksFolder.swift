import Foundation

// The library: one folder picked once (normally iCloud Drive's books folder) and listed from then on, so books never
// have to be found through the file picker again. Every book inside is readable through the folder's security scope,
// which is held for the life of the app; it has to be in place before the view model restores the previous session's
// documents, which is why the view model creates this first.
@MainActor
@Observable
final class BooksFolder {
	private(set) var folderURL: URL?
	private(set) var books: [URL] = []

	private static let bookmarkKey = "pb_books_folder"

	init() {
		guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
		var isStale = false
		guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else { return }
		adopt(url)
		if isStale { saveBookmark(url) }
	}

	func choose(_ url: URL) {
		folderURL?.stopAccessingSecurityScopedResource()
		adopt(url)
		saveBookmark(url)
	}

	func refresh() {
		guard let folderURL else { return }
		let items = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
		books = Set(items.compactMap(Self.book(for:))).sorted {
			$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
		}
	}

	static func title(of book: URL) -> String {
		book.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
	}

	// The engine reads books by path, so a book iCloud has not downloaded yet must be brought down first; a coordinated
	// read is what asks iCloud for it, and it returns once the file is on the device.
	nonisolated static func download(_ book: URL) async throws -> URL {
		try await withCheckedThrowingContinuation { continuation in
			let intent = NSFileAccessIntent.readingIntent(with: book)
			NSFileCoordinator().coordinate(with: [intent], queue: OperationQueue()) { error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume(returning: intent.url)
				}
			}
		}
	}

	private func adopt(_ url: URL) {
		_ = url.startAccessingSecurityScopedResource()
		folderURL = url
		refresh()
	}

	private func saveBookmark(_ url: URL) {
		guard let data = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
		UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
	}

	// Books still only in iCloud can be listed as hidden ".<name>.icloud" placeholders; they stand for the real file.
	private static func book(for item: URL) -> URL? {
		let name = item.lastPathComponent
		if name.hasPrefix("."), name.hasSuffix(".icloud") {
			return item.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
		}
		if name.hasPrefix(".") || item.pathExtension == "paperback" { return nil }
		if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return nil }
		return item
	}
}
