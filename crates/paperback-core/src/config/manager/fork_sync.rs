//! The fork's sync of reading position and bookmarks between devices (its DESIGN.md "Sync").
//!
//! Every device keeps one value of its own in a [`SyncStore`], Apple's iCloud key-value store in
//! both apps, under `device.<name>`, and reads the others'. A value is TOML holding an entry per
//! book, under the content-hash key the config already files books by, so the same book matches
//! on every device whatever its path. Position and bookmarks carry their own save times and the
//! newest of each wins, so reading on one device never undoes a bookmark added on another.
//!
//! Positions in the store are in shared units rather than the local config's display units. The
//! Mac counts UTF-16 code units where the iPhone counts characters, and the Mac renders tables as
//! their text where the iPhone leaves a one-line placeholder, so the same place has different
//! offsets on the two. Shared units count characters with every table as one, which both buffers
//! agree on. A book whose two buffers still differ in length (a different engine version, say)
//! has its positions scaled, which lands near the right place rather than drifting from the start.
//!
//! The device's value is written from [`ConfigManager::flush`], so every save the apps already
//! make carries to the other device without either app knowing about sync beyond opening a book.

use std::{
	collections::{BTreeMap, HashMap},
	path::Path,
	sync::Arc,
	time::{SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};

use super::ConfigManager;
use crate::{
	config::settings::StoredBookmark,
	document::{Document, MarkerType},
	util::text::ch_width,
};

/// Where the devices' sync state is kept, given by the app. Both apps give Apple's iCloud key-value
/// store, which carries a value set on one device to the others on the same account.
#[cfg_attr(feature = "uniffi", uniffi::export(with_foreign))]
pub trait SyncStore: Send + Sync {
	fn get(&self, key: String) -> Option<String>;
	fn set(&self, key: String, value: String);
	fn keys(&self) -> Vec<String>;
}

const DEVICE_KEY_PREFIX: &str = "device.";

/// The save time of a place a device had before sync began. Every such place counts as equally old,
/// so each device keeps its own until the reader moves on one of them, and any of them wins over a
/// device that has nothing for the book.
const BEFORE_SYNC: u64 = 1;

#[derive(Default)]
pub(super) struct SyncState {
	store: Option<Arc<dyn SyncStore>>,
	device: String,
	own: SyncFile,
	/// Whether `own` holds what this device's stored value says. Until it does (the value will not
	/// read) it is never written, since that would replace every book in it with this run's.
	own_loaded: bool,
	/// Books opened this run, by key. Only these can be converted between local and shared units,
	/// which needs the parsed text.
	open: HashMap<String, OpenBook>,
	dirty: bool,
}

struct OpenBook {
	path: String,
	units: SharedUnits,
}

#[derive(Serialize, Deserialize, Default, Clone, Debug)]
struct SyncFile {
	#[serde(default)]
	books: BTreeMap<String, Entry>,
}

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq, Eq)]
struct Entry {
	/// The book's file name, for whoever looks inside the file.
	#[serde(default)]
	name: String,
	/// The book's length in shared units on the device that wrote the entry.
	#[serde(default)]
	length: u64,
	#[serde(default)]
	position: u64,
	/// Milliseconds since 1970, or [`BEFORE_SYNC`] for a place a device had before sync began, and
	/// zero for a book it had nothing for, so anything at all wins over that.
	#[serde(default)]
	position_saved: u64,
	#[serde(default)]
	bookmarks_saved: u64,
	#[serde(default)]
	bookmarks: Vec<SyncBookmark>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
struct SyncBookmark {
	start: u64,
	end: u64,
	#[serde(default, skip_serializing_if = "String::is_empty")]
	note: String,
}

/// Converts a book's local display offsets to shared units and back.
struct SharedUnits {
	/// Character offsets of the characters wider than one display unit, and the display offset of
	/// each. Empty where display units are characters.
	wide_chars: Vec<usize>,
	wide_display: Vec<usize>,
	/// Tables as character ranges, in order, without overlaps.
	tables: Vec<(usize, usize)>,
	chars: usize,
	length: u64,
}

impl SharedUnits {
	fn new(doc: &Document) -> Self {
		let buffer = &doc.buffer;
		let wide_chars: Vec<usize> =
			buffer.content.chars().enumerate().filter(|(_, ch)| ch_width(*ch) > 1).map(|(index, _)| index).collect();
		let wide_display = wide_chars.iter().enumerate().map(|(count, index)| index + count).collect();
		let mut ranges: Vec<(usize, usize)> = buffer
			.markers
			.iter()
			.filter(|marker| marker.mtype == MarkerType::Table && marker.length > 0)
			.map(|marker| {
				(
					buffer.char_index_for_display(marker.position),
					buffer.char_index_for_display(marker.position + marker.length),
				)
			})
			.collect();
		ranges.sort_unstable();
		let mut tables: Vec<(usize, usize)> = Vec::new();
		for (start, end) in ranges {
			match tables.last_mut() {
				Some(last) if start < last.1 => last.1 = last.1.max(end),
				_ => tables.push((start, end)),
			}
		}
		let chars = buffer.content.chars().count();
		let removed: usize = tables.iter().map(|(start, end)| end - start - 1).sum();
		let length = (chars - removed) as u64;
		Self { wide_chars, wide_display, tables, chars, length }
	}

	fn to_shared(&self, display: i64) -> u64 {
		let display = usize::try_from(display.max(0)).unwrap_or(0);
		let wide_before = self.wide_display.partition_point(|&offset| offset < display);
		let ch = (display - wide_before).min(self.chars);
		let mut removed = 0;
		for &(start, end) in &self.tables {
			if ch >= end {
				removed += end - start - 1;
			} else if ch >= start {
				return (start - removed) as u64;
			} else {
				break;
			}
		}
		(ch - removed) as u64
	}

	fn to_display(&self, shared: u64) -> i64 {
		let shared = usize::try_from(shared).unwrap_or(usize::MAX);
		let mut removed = 0;
		let mut ch = None;
		for &(start, end) in &self.tables {
			let table = start - removed;
			if shared <= table {
				ch = Some(shared + removed);
				break;
			}
			removed += end - start - 1;
		}
		let ch = ch.unwrap_or_else(|| shared.saturating_add(removed)).min(self.chars);
		i64::try_from(ch + self.wide_chars.partition_point(|&index| index < ch)).unwrap_or(i64::MAX)
	}

	/// `shared` from a device whose copy of the book is `from_length` long, in this copy's units.
	fn to_display_from(&self, shared: u64, from_length: u64) -> i64 {
		if from_length == 0 || from_length == self.length {
			return self.to_display(shared);
		}
		let scaled = u128::from(shared) * u128::from(self.length) / u128::from(from_length);
		self.to_display(u64::try_from(scaled).unwrap_or(u64::MAX))
	}

	fn bookmarks_to_shared(&self, bookmarks: &[StoredBookmark]) -> Vec<SyncBookmark> {
		bookmarks
			.iter()
			.filter(|bookmark| bookmark.audio_ms.is_none())
			.map(|bookmark| SyncBookmark {
				start: self.to_shared(bookmark.start),
				end: self.to_shared(bookmark.end),
				note: bookmark.note.clone(),
			})
			.collect()
	}
}

impl ConfigManager {
	/// Starts syncing through `store` as `device`, which names this device's value there.
	pub fn sync_start(&self, device: &str, store: Arc<dyn SyncStore>) {
		if !self.initialized {
			return;
		}
		{
			let mut sync = self.sync.borrow_mut();
			sync.store = Some(store);
			sync.device = device.to_string();
			sync.own = SyncFile::default();
			sync.own_loaded = false;
			sync.dirty = false;
		}
		self.refresh_own();
	}

	/// Whether this device's sync entries hold the book at `path`.
	pub fn sync_knows(&self, path: &str) -> bool {
		let key = self.get_doc_key(path);
		self.sync.borrow().own.books.contains_key(&key)
	}

	#[must_use]
	pub fn sync_enabled(&self) -> bool {
		self.sync.borrow().store.is_some()
	}

	/// Takes the newest position and bookmarks for a book just parsed, before the app reads where
	/// to open it. True when something from another device was taken.
	pub fn sync_open(&self, path: &str, doc: &Document) -> bool {
		if !self.initialized || self.sync.borrow().store.is_none() || doc.audio.is_some() {
			return false;
		}
		let key = self.get_doc_key(path);
		let units = SharedUnits::new(doc);
		{
			let mut sync = self.sync.borrow_mut();
			if !sync.own.books.contains_key(&key) {
				let mut entry = self.local_entry(&key, path, &units);
				if entry.position > 0 || !entry.bookmarks.is_empty() {
					entry.position_saved = BEFORE_SYNC;
					entry.bookmarks_saved = BEFORE_SYNC;
					sync.dirty = true;
				}
				sync.own.books.insert(key.clone(), entry);
			}
			sync.open.insert(key.clone(), OpenBook { path: path.to_string(), units });
		}
		self.refresh_own();
		self.restore_blank(&key);
		let others = self.read_other_devices();
		self.take_newer(&key, &others).0
	}

	/// Converts with a book's text as it is now, after the app parsed it again (a reload, or a change
	/// to how tables are shown).
	pub fn sync_reparsed(&self, path: &str, doc: &Document) {
		let key = self.get_doc_key(path);
		if let Some(book) = self.sync.borrow_mut().open.get_mut(&key) {
			book.units = SharedUnits::new(doc);
		}
	}

	/// Takes anything newer from other devices for the books open this run, for when the app comes
	/// back to the front. Returns each book whose position moved, with where it moved to.
	pub fn sync_pull(&self) -> Vec<(String, i64)> {
		if !self.initialized || self.sync.borrow().store.is_none() {
			return Vec::new();
		}
		self.refresh_own();
		let others = self.read_other_devices();
		// Collected first: taking newer state borrows the sync state mutably, which iterating it here
		// would still be holding.
		#[allow(clippy::needless_collect)]
		let books: Vec<(String, String)> =
			self.sync.borrow().open.iter().map(|(key, book)| (key.clone(), book.path.clone())).collect();
		books
			.into_iter()
			.filter_map(|(key, path)| self.take_newer(&key, &others).1.map(|position| (path, position)))
			.collect()
	}

	/// Records local changes to the open books in this device's entries and writes its file when
	/// anything changed. Called from [`ConfigManager::flush`].
	pub(super) fn sync_push(&self) {
		if self.sync.borrow().store.is_none() {
			return;
		}
		self.refresh_own();
		let mut guard = self.sync.borrow_mut();
		let sync = &mut *guard;
		let keys: Vec<String> = sync.open.keys().cloned().collect();
		for key in keys {
			self.record_local_changes(sync, &key);
		}
		let Some(store) = sync.store.as_ref() else { return };
		if !sync.dirty || !sync.own_loaded {
			return;
		}
		let Ok(text) = toml::to_string(&sync.own) else { return };
		store.set(format!("{DEVICE_KEY_PREFIX}{}", sync.device), text);
		sync.dirty = false;
	}

	/// Stamps whatever differs between the local config and this device's entry for an open book
	/// as saved now. A stamp never goes back past the last one, so a clock behind another device's
	/// still makes each new save count as newer than what was taken from it.
	fn record_local_changes(&self, sync: &mut SyncState, key: &str) {
		let Some(book) = sync.open.get(key) else { return };
		let current = self.local_entry(key, &book.path, &book.units);
		let entry = sync.own.books.entry(key.to_string()).or_default();
		let now = now_ms();
		let position_changed = entry.position != current.position;
		if position_changed {
			entry.position = current.position;
			entry.position_saved = now.max(entry.position_saved + 1);
		}
		let bookmarks_changed = entry.bookmarks != current.bookmarks;
		if bookmarks_changed {
			entry.bookmarks = current.bookmarks;
			entry.bookmarks_saved = now.max(entry.bookmarks_saved + 1);
		}
		if position_changed || bookmarks_changed {
			entry.name = current.name;
			entry.length = current.length;
			sync.dirty = true;
		}
	}

	/// This device's current state for a book, in shared units, with no save times.
	fn local_entry(&self, key: &str, path: &str, units: &SharedUnits) -> Entry {
		let data = self.data.borrow();
		let doc = data.documents.get(key);
		Entry {
			name: Path::new(path).file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default(),
			length: units.length,
			position: units.to_shared(doc.map_or(0, |doc| doc.last_position)),
			position_saved: 0,
			bookmarks_saved: 0,
			bookmarks: doc.map(|doc| units.bookmarks_to_shared(&doc.bookmarks)).unwrap_or_default(),
		}
	}

	/// Reads this device's own stored value once it can be read. What this run did meanwhile is kept
	/// where it is newer, and books the local config has nothing for take what the value says.
	fn refresh_own(&self) {
		let loaded = {
			let mut guard = self.sync.borrow_mut();
			let sync = &mut *guard;
			if sync.own_loaded {
				return;
			}
			let Some(store) = sync.store.as_ref() else { return };
			let stored = match store.get(format!("{DEVICE_KEY_PREFIX}{}", sync.device)) {
				// Unreadable: left alone, and never overwritten, until it reads.
				Some(text) => match toml::from_str(&text) {
					Ok(stored) => stored,
					Err(_) => return,
				},
				None => SyncFile::default(),
			};
			for (key, stored) in stored.books {
				let entry = sync.own.books.entry(key).or_insert_with(|| stored.clone());
				if stored.position_saved > entry.position_saved {
					entry.position = stored.position;
					entry.position_saved = stored.position_saved;
					entry.length = stored.length;
				}
				if stored.bookmarks_saved > entry.bookmarks_saved {
					entry.bookmarks = stored.bookmarks;
					entry.bookmarks_saved = stored.bookmarks_saved;
					entry.length = stored.length;
				}
			}
			sync.own_loaded = true;
			sync.open.keys().cloned().collect::<Vec<_>>()
		};
		for key in loaded {
			self.restore_blank(&key);
		}
	}

	/// A config that has nothing for a book (a reinstall, a fresh settings folder, a forgotten
	/// document) takes this device's own entry for it rather than having the blank stamped as a
	/// change that would wipe the book on every device.
	fn restore_blank(&self, key: &str) {
		let own = {
			let sync = self.sync.borrow();
			let Some(book) = sync.open.get(key) else { return };
			let local = self.local_entry(key, &book.path, &book.units);
			if local.position > 0 || !local.bookmarks.is_empty() {
				return;
			}
			match sync.own.books.get(key) {
				Some(own) if own.position > 0 || !own.bookmarks.is_empty() => own.clone(),
				_ => return,
			}
		};
		self.apply(key, Some(&own), Some(&own));
	}

	/// Applies the newest position and the newest bookmarks another device has for `key` where they
	/// are newer than this device's. Returns whether anything was taken, and the new local
	/// position if it moved.
	fn take_newer(&self, key: &str, others: &[SyncFile]) -> (bool, Option<i64>) {
		let own = {
			let mut guard = self.sync.borrow_mut();
			let sync = &mut *guard;
			if !sync.open.contains_key(key) {
				return (false, None);
			}
			// A local change not yet saved is stamped first, or taking would quietly drop it.
			self.record_local_changes(sync, key);
			sync.own.books.get(key).cloned().unwrap_or_default()
		};
		let entries = || others.iter().filter_map(|file| file.books.get(key));
		let newest_position =
			entries().filter(|entry| entry.position_saved > own.position_saved).max_by_key(|e| e.position_saved);
		let newest_bookmarks =
			entries().filter(|entry| entry.bookmarks_saved > own.bookmarks_saved).max_by_key(|e| e.bookmarks_saved);
		if newest_position.is_none() && newest_bookmarks.is_none() {
			return (false, None);
		}
		(true, self.apply(key, newest_position, newest_bookmarks))
	}

	/// Writes a position and a bookmark list from an entry into the local config, converted to its
	/// units, and makes this device's entry say what it now holds with the save times of what it
	/// took. Otherwise the next flush would see a change and stamp it as new. Returns the new
	/// position if it moved.
	fn apply(&self, key: &str, position: Option<&Entry>, bookmarks: Option<&Entry>) -> Option<i64> {
		let mut guard = self.sync.borrow_mut();
		let sync = &mut *guard;
		let book = sync.open.get(key)?;
		let mut moved = None;
		{
			let units = &book.units;
			let mut data = self.data.borrow_mut();
			let doc = Self::doc_entry_mut(&mut data, key.to_string(), &book.path);
			if let Some(remote) = position {
				let local = units.to_display_from(remote.position, remote.length);
				if local != doc.last_position {
					doc.last_position = local;
					moved = Some(local);
				}
			}
			if let Some(remote) = bookmarks {
				doc.bookmarks.retain(|bookmark| bookmark.audio_ms.is_some());
				doc.bookmarks.extend(remote.bookmarks.iter().map(|bookmark| StoredBookmark {
					start: units.to_display_from(bookmark.start, remote.length),
					end: units.to_display_from(bookmark.end, remote.length),
					note: bookmark.note.clone(),
					audio_ms: None,
				}));
				doc.bookmarks.sort_by_key(|bookmark| (bookmark.start, bookmark.audio_ms));
			}
		}
		self.dirty.set(true);
		let own = sync.own.books.get(key).cloned().unwrap_or_default();
		let mut entry = self.local_entry(key, &book.path, &book.units);
		entry.position_saved = position.map_or(own.position_saved, |remote| remote.position_saved);
		entry.bookmarks_saved = bookmarks.map_or(own.bookmarks_saved, |remote| remote.bookmarks_saved);
		sync.own.books.insert(key.to_string(), entry);
		sync.dirty = true;
		moved
	}

	fn read_other_devices(&self) -> Vec<SyncFile> {
		let sync = self.sync.borrow();
		let Some(store) = sync.store.as_ref() else { return Vec::new() };
		let own = format!("{DEVICE_KEY_PREFIX}{}", sync.device);
		store
			.keys()
			.into_iter()
			.filter(|key| key.starts_with(DEVICE_KEY_PREFIX) && *key != own)
			.filter_map(|key| toml::from_str(&store.get(key)?).ok())
			.collect()
	}
}

fn now_ms() -> u64 {
	SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(0))
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::{
		document::{DocumentBuffer, Marker, ParserContext},
		util::test_support::TempDir,
	};

	fn doc(content: &str, tables: &[(usize, usize)]) -> Document {
		let mut buffer = DocumentBuffer::with_content(content.to_string());
		for &(start, end) in tables {
			let position = buffer.display_index_for_char(start);
			let mut marker = Marker::new(MarkerType::Table, position);
			marker.length = buffer.display_index_for_char(end) - position;
			buffer.add_marker(marker);
		}
		let mut doc = Document::new();
		doc.set_buffer(buffer);
		doc
	}

	/// What the iCloud key-value store does for the apps, shared between the devices of a test.
	#[derive(Default)]
	struct MemoryStore(std::sync::Mutex<HashMap<String, String>>);

	impl SyncStore for MemoryStore {
		fn get(&self, key: String) -> Option<String> {
			self.0.lock().unwrap().get(&key).cloned()
		}

		fn set(&self, key: String, value: String) {
			self.0.lock().unwrap().insert(key, value);
		}

		fn keys(&self) -> Vec<String> {
			self.0.lock().unwrap().keys().cloned().collect()
		}
	}

	fn device(store: &Arc<MemoryStore>, name: &str) -> ConfigManager {
		let config = ConfigManager::in_memory();
		config.sync_start(name, store.clone());
		config
	}

	/// The same book's file at two paths, as the Mac and the iPhone each keep it. The config keys a
	/// book by its contents, so both paths are the same book.
	fn copies(folder: &TempDir) -> (String, String) {
		(folder.write_str("mac/book.epub", "the book"), folder.write_str("phone/book.epub", "the book"))
	}

	/// Two save times on different devices are never the same millisecond in real use.
	fn tick() {
		std::thread::sleep(std::time::Duration::from_millis(2));
	}

	#[test]
	fn a_table_counts_as_one_unit_and_positions_inside_it_land_on_its_start() {
		let doc = doc("Intro\nA\tB\nC\tD\nAfter\n", &[(6, 13)]);
		let units = SharedUnits::new(&doc);
		assert_eq!(units.length, 20 - 7 + 1);
		assert_eq!(units.to_shared(3), 3);
		assert_eq!(units.to_shared(6), 6);
		assert_eq!(units.to_shared(9), 6);
		assert_eq!(units.to_shared(14), 8);
		assert_eq!(units.to_display(6), 6);
		assert_eq!(units.to_display(8), 14);
	}

	#[test]
	fn the_same_place_has_the_same_shared_offset_whichever_way_the_table_was_rendered() {
		let inline = doc("Intro\nA\tB\nC\tD\nAfter\n", &[(6, 13)]);
		let placeholder = doc("Intro\n[Table]: A B\nAfter\n", &[(6, 18)]);
		let inline = SharedUnits::new(&inline);
		let placeholder = SharedUnits::new(&placeholder);
		assert_eq!(inline.length, placeholder.length);
		let after_inline = 14;
		let after_placeholder = 19;
		assert_eq!(inline.to_shared(after_inline), placeholder.to_shared(after_placeholder));
		assert_eq!(placeholder.to_display(inline.to_shared(after_inline)), after_placeholder);
	}

	#[test]
	fn characters_wider_than_one_display_unit_are_counted_once() {
		let doc = doc("a\u{1F600}b\nnext\n", &[]);
		let units = SharedUnits::new(&doc);
		let next = doc.buffer.display_index_for_char(4);
		assert_eq!(units.to_shared(i64::try_from(next).unwrap()), 4);
		assert_eq!(units.to_display(4), i64::try_from(next).unwrap());
	}

	#[test]
	fn a_book_of_another_length_has_its_position_scaled() {
		let units = SharedUnits::new(&doc(&"x".repeat(1000), &[]));
		assert_eq!(units.to_display_from(250, 500), 500);
	}

	#[test]
	fn a_position_and_a_bookmark_cross_from_one_device_to_the_other_and_back() {
		let folder = TempDir::new("sync-round-trip");
		let store = Arc::new(MemoryStore::default());
		let (a, b) = copies(&folder);
		let book = doc("First paragraph.\nSecond paragraph.\nThird paragraph.\n", &[]);
		let mac = device(&store, "mac");
		let phone = device(&store, "iphone");
		mac.sync_open(&a, &book);
		mac.set_document_position(&a, 17);
		mac.add_bookmark(&a, 35, 35, "Third");
		mac.flush();
		tick();
		assert!(phone.sync_open(&b, &book));
		assert_eq!(phone.get_document_position(&b), 17);
		assert_eq!(phone.get_bookmarks(&b)[0].note, "Third");
		phone.set_document_position(&b, 35);
		phone.remove_bookmark(&b, 35, 35);
		phone.flush();
		tick();
		assert_eq!(mac.sync_pull(), vec![(a.clone(), 35)]);
		assert!(mac.get_bookmarks(&a).is_empty(), "a deleted bookmark stays deleted");
	}

	#[test]
	fn taking_another_devices_state_does_not_send_it_back_as_new() {
		let folder = TempDir::new("sync-no-echo");
		let store = Arc::new(MemoryStore::default());
		let (a, b) = copies(&folder);
		let book = doc("One.\nTwo.\n", &[]);
		let mac = device(&store, "mac");
		let phone = device(&store, "iphone");
		mac.sync_open(&a, &book);
		mac.set_document_position(&a, 5);
		mac.flush();
		tick();
		phone.sync_open(&b, &book);
		phone.flush();
		let saved = phone.sync.borrow().own.books.values().next().unwrap().position_saved;
		let mac_saved = mac.sync.borrow().own.books.values().next().unwrap().position_saved;
		assert_eq!(saved, mac_saved);
		tick();
		assert!(mac.sync_pull().is_empty());
	}

	#[test]
	fn reading_on_one_device_keeps_a_bookmark_added_on_the_other() {
		let folder = TempDir::new("sync-separate-times");
		let store = Arc::new(MemoryStore::default());
		let (a, b) = copies(&folder);
		let book = doc("One.\nTwo.\nThree.\n", &[]);
		let mac = device(&store, "mac");
		let phone = device(&store, "iphone");
		mac.sync_open(&a, &book);
		phone.sync_open(&b, &book);
		mac.add_bookmark(&a, 5, 5, "");
		mac.flush();
		tick();
		phone.set_document_position(&b, 10);
		phone.flush();
		tick();
		mac.sync_pull();
		phone.sync_pull();
		assert_eq!(mac.get_document_position(&a), 10);
		assert_eq!(phone.get_bookmarks(&b).len(), 1);
	}

	/// What a device knew before sync is older than any real save.
	#[test]
	fn state_from_before_sync_gives_way_to_any_real_save() {
		let folder = TempDir::new("sync-old-state");
		let store = Arc::new(MemoryStore::default());
		let (a, b) = copies(&folder);
		let book = doc("One.\nTwo.\nThree.\n", &[]);
		let mac = device(&store, "mac");
		mac.sync_open(&a, &book);
		mac.set_document_position(&a, 5);
		mac.flush();
		tick();
		let phone = ConfigManager::in_memory();
		phone.set_document_position(&b, 10);
		phone.sync_start("iphone", store);
		phone.sync_open(&b, &book);
		assert_eq!(phone.get_document_position(&b), 5);
	}

	/// Places from before sync count as equally old: each device keeps its own, and one with nothing
	/// for the book takes the other's.
	#[test]
	fn places_from_before_sync_stay_put_but_fill_a_device_that_has_none() {
		let folder = TempDir::new("sync-before-sync");
		let store = Arc::new(MemoryStore::default());
		let (a, b) = copies(&folder);
		let c = folder.write_str("third/book.epub", "the book");
		let book = doc("One.\nTwo.\nThree.\n", &[]);
		let mac = ConfigManager::in_memory();
		mac.set_document_position(&a, 5);
		mac.sync_start("mac", store.clone());
		mac.sync_open(&a, &book);
		mac.flush();
		let phone = ConfigManager::in_memory();
		phone.set_document_position(&b, 10);
		phone.sync_start("iphone", store.clone());
		phone.sync_open(&b, &book);
		assert_eq!(phone.get_document_position(&b), 10);
		let ipad = device(&store, "ipad");
		ipad.sync_open(&c, &book);
		assert_eq!(ipad.get_document_position(&c), 5);
	}

	/// A reinstalled app, or one run with fresh settings, has nothing for the book; what its own
	/// stored value remembers is taken back instead of the blank being sent out as a change.
	#[test]
	fn fresh_settings_take_back_this_devices_stored_value_instead_of_wiping_the_book() {
		let folder = TempDir::new("sync-fresh-settings");
		let store = Arc::new(MemoryStore::default());
		let (a, b) = copies(&folder);
		let book = doc("One.\nTwo.\nThree.\n", &[]);
		let mac = device(&store, "mac");
		let phone = device(&store, "iphone");
		mac.sync_open(&a, &book);
		phone.sync_open(&b, &book);
		phone.set_document_position(&b, 10);
		phone.add_bookmark(&b, 5, 5, "");
		phone.flush();
		tick();
		mac.sync_pull();
		let reinstalled = device(&store, "iphone");
		reinstalled.sync_open(&b, &book);
		reinstalled.flush();
		assert_eq!(reinstalled.get_document_position(&b), 10);
		assert_eq!(reinstalled.get_bookmarks(&b).len(), 1);
		tick();
		mac.sync_pull();
		assert_eq!(mac.get_document_position(&a), 10);
		assert_eq!(mac.get_bookmarks(&a).len(), 1);
	}

	#[test]
	fn a_device_whose_clock_is_behind_still_gets_its_moves_across() {
		let folder = TempDir::new("sync-clock");
		let store = Arc::new(MemoryStore::default());
		let (a, b) = copies(&folder);
		let book = doc("One.\nTwo.\nThree.\n", &[]);
		let mac = device(&store, "mac");
		mac.sync_open(&a, &book);
		mac.set_document_position(&a, 5);
		mac.flush();
		// The Mac's clock a minute ahead of the phone's.
		mac.sync.borrow_mut().own.books.values_mut().for_each(|entry| entry.position_saved += 60_000);
		mac.sync.borrow_mut().dirty = true;
		mac.flush();
		let phone = device(&store, "iphone");
		phone.sync_open(&b, &book);
		phone.set_document_position(&b, 10);
		phone.flush();
		assert_eq!(mac.sync_pull(), vec![(a, 10)]);
	}

	/// A damaged value: writing over it would leave only this run's books.
	#[test]
	fn an_unreadable_stored_value_is_never_overwritten() {
		let folder = TempDir::new("sync-unreadable");
		let store = Arc::new(MemoryStore::default());
		let (a, _) = copies(&folder);
		let book = doc("One.\nTwo.\n", &[]);
		store.set("device.mac".to_string(), "not toml [".to_string());
		let mac = device(&store, "mac");
		mac.sync_open(&a, &book);
		mac.set_document_position(&a, 5);
		mac.flush();
		assert_eq!(store.get("device.mac".to_string()).unwrap(), "not toml [");
	}

	#[test]
	fn a_move_not_yet_saved_survives_taking_bookmarks_from_another_device() {
		let folder = TempDir::new("sync-unsaved-move");
		let store = Arc::new(MemoryStore::default());
		let (a, b) = copies(&folder);
		let book = doc("One.\nTwo.\nThree.\n", &[]);
		let mac = device(&store, "mac");
		let phone = device(&store, "iphone");
		mac.sync_open(&a, &book);
		phone.sync_open(&b, &book);
		mac.add_bookmark(&a, 5, 5, "");
		mac.flush();
		tick();
		phone.set_document_position(&b, 10);
		phone.sync_pull();
		phone.flush();
		tick();
		mac.sync_pull();
		assert_eq!(phone.get_bookmarks(&b).len(), 1);
		assert_eq!(mac.get_document_position(&a), 10);
	}

	#[test]
	fn nothing_is_written_until_something_changes() {
		let store = Arc::new(MemoryStore::default());
		let mac = device(&store, "mac");
		mac.flush();
		assert!(store.get("device.mac".to_string()).is_none());
	}

	fn fixture(name: &str) -> Option<String> {
		let path =
			Path::new(&std::env::var_os("HOME")?).join("Library/Mobile Documents/com~apple~CloudDocs/books").join(name);
		path.is_file().then(|| path.to_string_lossy().into_owned())
	}

	/// A book's text with each table replaced by one character, and its length in shared units.
	fn shared_text(path: &str, inline: bool) -> (String, u64, usize) {
		let context = ParserContext::new(path.to_string()).with_render_tables_inline(inline);
		let doc = crate::parser::parse_document(&context).expect("parse fixture");
		let units = SharedUnits::new(&doc);
		let mut text = String::new();
		let mut tables = units.tables.iter().peekable();
		let mut skip_to = 0;
		for (index, ch) in doc.buffer.content.chars().enumerate() {
			if index < skip_to {
				continue;
			}
			if let Some(&&(start, end)) = tables.peek()
				&& index == start
			{
				text.push('\u{FFFC}');
				skip_to = end;
				tables.next();
				continue;
			}
			text.push(ch);
		}
		(text, units.length, units.tables.len())
	}

	/// The Mac renders tables inline and the iPhone does not; everything outside the tables has to
	/// come out the same, or synced positions after the first table would drift.
	#[test]
	fn the_prize_has_the_same_shared_text_with_tables_inline_or_not() {
		let Some(path) = fixture("The_Prize_rashad_naqeeb.epub") else { return };
		let (inline, inline_length, tables) = shared_text(&path, true);
		let (placeholder, placeholder_length, _) = shared_text(&path, false);
		assert!(tables > 0);
		assert_eq!(inline_length, placeholder_length);
		assert!(inline == placeholder, "the shared text differs outside the tables");
	}
}
