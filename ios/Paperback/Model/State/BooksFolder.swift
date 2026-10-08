import Foundation

enum BookSort: String, CaseIterable {
	case title, recent
}

// The library: one folder picked once (normally iCloud Drive's books folder) and listed from then on, so books never
// have to be found through a file picker. Every book inside is readable through the folder's security scope, which is
// held for the life of the app.
@MainActor
@Observable
final class BooksFolder {
	private(set) var folderURL: URL?
	private(set) var books: [URL] = []
	var sort: BookSort = BookSort(rawValue: UserDefaults.standard.string(forKey: BooksFolder.sortKey) ?? "") ?? .title {
		didSet {
			UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey)
			refresh()
		}
	}
	// When each book was last opened, keyed by file name rather than path so it survives the folder being chosen again.
	private var lastRead: [String: Double] = UserDefaults.standard.dictionary(forKey: BooksFolder.lastReadKey) as? [String: Double] ?? [:]

	private static let bookmarkKey = "pb_books_folder"
	private static let sortKey = "pb_books_sort"
	private static let lastReadKey = "pb_books_last_read"

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
		let found = Set(items.compactMap(Self.book(for:)))
		let byTitle = found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
		switch sort {
		case .title:
			books = byTitle
		case .recent:
			// Books never opened keep their title order after every book that has been.
			let read = byTitle.filter { lastRead[$0.lastPathComponent] != nil }.sorted { lastRead[$0.lastPathComponent]! > lastRead[$1.lastPathComponent]! }
			books = read + byTitle.filter { lastRead[$0.lastPathComponent] == nil }
		}
	}

	func markRead(_ book: URL) {
		lastRead[book.lastPathComponent] = Date().timeIntervalSince1970
		UserDefaults.standard.set(lastRead, forKey: Self.lastReadKey)
		if sort == .recent { refresh() }
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
