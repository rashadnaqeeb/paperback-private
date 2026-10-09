//! The fork's sync of reading position and bookmarks between devices (its DESIGN.md "Sync").
//!
//! Every device writes one file of its own into a shared folder, `<device>.toml`, and reads the
//! others'. A file holds an entry per book, under the content-hash key the config already files
//! books by, so the same book matches on every device whatever its path. Position and bookmarks
//! carry their own save times and the newest of each wins, so reading on one device never undoes
//! a bookmark added on another.
//!
//! Positions in the files are in shared units rather than the local config's display units. The
//! Mac counts UTF-16 code units where the iPhone counts characters, and the Mac renders tables as
//! their text where the iPhone leaves a one-line placeholder, so the same place has different
//! offsets on the two. Shared units count characters with every table as one, which both buffers
//! agree on. A book whose two buffers still differ in length (a different engine version, say)
//! has its positions scaled, which lands near the right place rather than drifting from the start.
//!
//! The device file is written from [`ConfigManager::flush`], so every save the apps already make
//! carries to the other device without either app knowing about sync beyond opening a book.

use std::{
	collections::{BTreeMap, HashMap},
	fs,
	path::{Path, PathBuf},
	time::{SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};

use super::ConfigManager;
use crate::{
	config::settings::StoredBookmark,
	document::{Document, MarkerType},
	util::text::ch_width,
};

#[derive(Default)]
pub(super) struct SyncState {
	folder: Option<PathBuf>,
	device: String,
	own: SyncFile,
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
	/// Milliseconds since 1970. Zero for state that was there before sync and whose age is
	/// unknown, so any real save on another device wins over it.
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
	/// Starts syncing through `folder` as `device`, which names this device's file there.
	pub fn sync_configure(&self, folder: &Path, device: &str) {
		// An empty folder would put the files wherever the app happens to be running.
		if !self.initialized || folder.as_os_str().is_empty() || fs::create_dir_all(folder).is_err() {
			return;
		}
		let mut sync = self.sync.borrow_mut();
		sync.own = read_sync_file(&folder.join(format!("{device}.toml"))).unwrap_or_default();
		sync.folder = Some(folder.to_path_buf());
		sync.device = device.to_string();
	}

	/// Takes the newest position and bookmarks for a book just parsed, before the app reads where
	/// to open it. True when something from another device was taken.
	pub fn sync_open(&self, path: &str, doc: &Document) -> bool {
		if !self.initialized || self.sync.borrow().folder.is_none() || doc.audio.is_some() {
			return false;
		}
		let key = self.get_doc_key(path);
		let units = SharedUnits::new(doc);
		{
			let mut sync = self.sync.borrow_mut();
			if !sync.own.books.contains_key(&key) {
				let entry = self.local_entry(&key, path, &units, 0, 0);
				sync.own.books.insert(key.clone(), entry);
				sync.dirty = true;
			}
			sync.open.insert(key.clone(), OpenBook { path: path.to_string(), units });
		}
		let others = self.read_other_devices();
		self.take_newer(&key, &others).0
	}

	/// Takes anything newer from other devices for the books open this run, for when the app comes
	/// back to the front. Returns each book whose position moved, with where it moved to.
	pub fn sync_pull(&self) -> Vec<(String, i64)> {
		if !self.initialized || self.sync.borrow().folder.is_none() {
			return Vec::new();
		}
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
		let mut guard = self.sync.borrow_mut();
		let sync = &mut *guard;
		let Some(folder) = sync.folder.clone() else { return };
		let now = now_ms();
		for (key, book) in &sync.open {
			let current = self.local_entry(key, &book.path, &book.units, now, now);
			let entry = sync.own.books.entry(key.clone()).or_default();
			let position_changed = entry.position != current.position;
			if position_changed {
				entry.position = current.position;
				entry.position_saved = now;
			}
			let bookmarks_changed = entry.bookmarks != current.bookmarks;
			if bookmarks_changed {
				entry.bookmarks = current.bookmarks;
				entry.bookmarks_saved = now;
			}
			if position_changed || bookmarks_changed {
				entry.name = current.name;
				entry.length = current.length;
				sync.dirty = true;
			}
		}
		if !sync.dirty {
			return;
		}
		let Ok(text) = toml::to_string_pretty(&sync.own) else { return };
		let target = folder.join(format!("{}.toml", sync.device));
		// Written beside the file and renamed over it, so iCloud never uploads half a file.
		let temporary = folder.join(format!(".{}.toml.tmp", sync.device));
		if fs::write(&temporary, text).is_ok() && fs::rename(&temporary, &target).is_ok() {
			sync.dirty = false;
		}
	}

	/// This device's current state for a book, in shared units, stamped with the given save times.
	fn local_entry(
		&self,
		key: &str,
		path: &str,
		units: &SharedUnits,
		position_saved: u64,
		bookmarks_saved: u64,
	) -> Entry {
		let data = self.data.borrow();
		let doc = data.documents.get(key);
		Entry {
			name: Path::new(path).file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default(),
			length: units.length,
			position: units.to_shared(doc.map_or(0, |doc| doc.last_position)),
			position_saved,
			bookmarks_saved,
			bookmarks: doc.map(|doc| units.bookmarks_to_shared(&doc.bookmarks)).unwrap_or_default(),
		}
	}

	/// Applies the newest position and the newest bookmarks another device has for `key` where they
	/// are newer than this device's. Returns whether anything was taken, and the new local
	/// position if it moved.
	fn take_newer(&self, key: &str, others: &[SyncFile]) -> (bool, Option<i64>) {
		let mut guard = self.sync.borrow_mut();
		let sync = &mut *guard;
		let Some(book) = sync.open.get(key) else { return (false, None) };
		let path = book.path.clone();
		let own = sync.own.books.get(key).cloned().unwrap_or_default();
		let entries = || others.iter().filter_map(|file| file.books.get(key));
		let newest_position =
			entries().filter(|entry| entry.position_saved > own.position_saved).max_by_key(|e| e.position_saved);
		let newest_bookmarks =
			entries().filter(|entry| entry.bookmarks_saved > own.bookmarks_saved).max_by_key(|e| e.bookmarks_saved);
		if newest_position.is_none() && newest_bookmarks.is_none() {
			return (false, None);
		}
		let mut moved = None;
		{
			let units = &book.units;
			let mut data = self.data.borrow_mut();
			let doc = Self::doc_entry_mut(&mut data, key.to_string(), &path);
			if let Some(remote) = newest_position {
				let position = units.to_display_from(remote.position, remote.length);
				if position != doc.last_position {
					doc.last_position = position;
					moved = Some(position);
				}
			}
			if let Some(remote) = newest_bookmarks {
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
		// This device's entry now says what it holds, in its own units, with the save time of what
		// it took. Otherwise the next flush would see a change and stamp it as new.
		let book = &sync.open[key];
		let mut entry = self.local_entry(key, &path, &book.units, own.position_saved, own.bookmarks_saved);
		if let Some(remote) = newest_position {
			entry.position_saved = remote.position_saved;
		}
		if let Some(remote) = newest_bookmarks {
			entry.bookmarks_saved = remote.bookmarks_saved;
		}
		sync.own.books.insert(key.to_string(), entry);
		sync.dirty = true;
		(true, moved)
	}

	fn read_other_devices(&self) -> Vec<SyncFile> {
		let sync = self.sync.borrow();
		let Some(folder) = sync.folder.as_ref() else { return Vec::new() };
		let own = format!("{}.toml", sync.device);
		let Ok(items) = fs::read_dir(folder) else { return Vec::new() };
		items
			.filter_map(Result::ok)
			.map(|item| item.path())
			.filter(|path| {
				let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
				// A leading dot is an iCloud placeholder or another device's file mid-write.
				!name.starts_with('.') && path.extension().is_some_and(|extension| extension == "toml") && name != own
			})
			.filter_map(|path| read_sync_file(&path))
			.collect()
	}
}

fn read_sync_file(path: &Path) -> Option<SyncFile> {
	toml::from_str(&fs::read_to_string(path).ok()?).ok()
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

	fn device(folder: &Path, name: &str) -> ConfigManager {
		let config = ConfigManager::in_memory();
		config.sync_configure(folder, name);
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
		let (a, b) = copies(&folder);
		let book = doc("First paragraph.\nSecond paragraph.\nThird paragraph.\n", &[]);
		let mac = device(folder.path(), "mac");
		let phone = device(folder.path(), "iphone");
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
		let (a, b) = copies(&folder);
		let book = doc("One.\nTwo.\n", &[]);
		let mac = device(folder.path(), "mac");
		let phone = device(folder.path(), "iphone");
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
		let (a, b) = copies(&folder);
		let book = doc("One.\nTwo.\nThree.\n", &[]);
		let mac = device(folder.path(), "mac");
		let phone = device(folder.path(), "iphone");
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

	/// What a device knew before sync existed has no save time, so it never overrides a real save.
	#[test]
	fn state_from_before_sync_gives_way_to_any_real_save() {
		let folder = TempDir::new("sync-old-state");
		let (a, b) = copies(&folder);
		let book = doc("One.\nTwo.\nThree.\n", &[]);
		let mac = device(folder.path(), "mac");
		mac.sync_open(&a, &book);
		mac.set_document_position(&a, 5);
		mac.flush();
		tick();
		let phone = ConfigManager::in_memory();
		phone.set_document_position(&b, 10);
		phone.sync_configure(folder.path(), "iphone");
		phone.sync_open(&b, &book);
		assert_eq!(phone.get_document_position(&b), 5);
	}

	#[test]
	fn nothing_is_written_until_something_changes() {
		let folder = TempDir::new("sync-quiet");
		let mac = device(folder.path(), "mac");
		mac.flush();
		assert!(!folder.path().join("mac.toml").exists());
	}

	fn fixture(name: &str) -> Option<String> {
		let path = Path::new(&std::env::var_os("HOME")?).join("Documents/home/books").join(name);
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
