import Foundation

// Where the engine keeps the devices' sync state (DESIGN.md "Sync"): Apple's iCloud key-value store, which the Mac app
// shares by naming the same store in its entitlements.
final class ICloudSyncStore: SyncStore {
	// Asked for each time rather than kept, since the class has to be Sendable for the engine.
	private var store: NSUbiquitousKeyValueStore { .default }

	init() {
		// Picks up what iCloud brought while the app was not running.
		store.synchronize()
	}

	func get(key: String) -> String? {
		store.string(forKey: key)
	}

	func set(key: String, value: String) {
		store.set(value, forKey: key)
	}

	func keys() -> [String] {
		Array(store.dictionaryRepresentation.keys)
	}
}
