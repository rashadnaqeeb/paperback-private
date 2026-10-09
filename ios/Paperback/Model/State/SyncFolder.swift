import Foundation

// The sync folder (DESIGN.md "Sync"): Paperback Sync inside the books folder, so the access the books folder already has
// covers it and there is nothing more to pick. The engine reads and writes the files in it; this brings the other
// devices' files down from iCloud before they are read and coordinates this device's writes.
enum SyncFolder {
	static let device = "iphone"

	static func url(in books: URL) -> URL {
		books.appendingPathComponent("Paperback Sync", isDirectory: true)
	}

	/// Brings the other devices' files down from iCloud, giving up after a few seconds so a phone that is offline still
	/// opens its book at once.
	nonisolated static func fetch(_ folder: URL) async {
		let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
		let files = items.map(realFile(for:)).filter { $0.pathExtension == "toml" && $0.lastPathComponent != "\(device).toml" }
		guard !files.isEmpty else { return }
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			let finish = Once { continuation.resume() }
			Task.detached {
				await withTaskGroup(of: Void.self) { group in
					for file in files {
						group.addTask { _ = try? await BooksFolder.download(file) }
					}
				}
				finish.run()
			}
			DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish.run() }
		}
	}

	/// Runs `write`, which writes this device's file, as a coordinated write, the way iCloud Drive asks anything writing
	/// into it to, so the change is seen and uploaded.
	static func coordinate(in folder: URL, _ write: () -> Void) {
		var error: NSError?
		var wrote = false
		NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent("\(device).toml"), options: .forReplacing, error: &error) { _ in
			write()
			wrote = true
		}
		if !wrote { write() }
	}

	// A file iCloud has not downloaded is listed as a hidden ".<name>.icloud" placeholder standing for the real file.
	private static func realFile(for item: URL) -> URL {
		let name = item.lastPathComponent
		guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return item }
		return item.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
	}
}

/// Runs its action the first time `run` is called and never again, from any thread.
private final class Once: @unchecked Sendable {
	private let lock = NSLock()
	private var action: (() -> Void)?

	init(_ action: @escaping () -> Void) {
		self.action = action
	}

	func run() {
		lock.lock()
		let action = self.action
		self.action = nil
		lock.unlock()
		action?()
	}
}
