//! Text bookmarks for the fork's iPhone in-book menu, stored where the desktop keeps its own so
//! sync can carry them between the two.

use super::ConfigManagerFfi;

#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BookmarkFfi {
	pub start: i64,
	pub end: i64,
	pub note: String,
}

// Owned `String` parameters because that is the signature UniFFI generates for.
#[allow(clippy::needless_pass_by_value)]
#[cfg_attr(feature = "uniffi", uniffi::export)]
impl ConfigManagerFfi {
	/// The document's text bookmarks in position order. Audio bookmarks are left out: the player
	/// has no bookmarks of its own yet.
	pub fn get_bookmarks_ffi(&self, path: String) -> Vec<BookmarkFfi> {
		self.inner
			.lock()
			.unwrap()
			.get_bookmarks(&path)
			.into_iter()
			.filter(|bm| bm.audio_ms.is_none())
			.map(|bm| BookmarkFfi { start: bm.start, end: bm.end, note: bm.note })
			.collect()
	}

	pub fn add_bookmark_ffi(&self, path: String, start: i64, end: i64, note: String) {
		self.inner.lock().unwrap().add_bookmark(&path, start, end, &note);
	}

	pub fn remove_bookmark_ffi(&self, path: String, start: i64, end: i64) {
		self.inner.lock().unwrap().remove_bookmark(&path, start, end);
	}

	pub fn update_bookmark_note_ffi(&self, path: String, start: i64, end: i64, note: String) {
		self.inner.lock().unwrap().update_bookmark_note(&path, start, end, &note);
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn bookmarks_round_trip_in_position_order() {
		let dir = std::env::temp_dir().join(format!("paperback-bookmarks-{}", std::process::id()));
		std::fs::create_dir_all(&dir).unwrap();
		let config = ConfigManagerFfi::new();
		assert!(config.initialize(dir.join("config.toml").to_string_lossy().into_owned()));
		let book = "/books/book.epub".to_string();
		config.add_bookmark_ffi(book.clone(), 50, 60, "Later".to_string());
		config.add_bookmark_ffi(book.clone(), 10, 20, "Earlier".to_string());
		let marks = config.get_bookmarks_ffi(book.clone());
		assert_eq!(marks.iter().map(|m| m.start).collect::<Vec<_>>(), vec![10, 50]);
		config.update_bookmark_note_ffi(book.clone(), 10, 20, "Renamed".to_string());
		assert_eq!(config.get_bookmarks_ffi(book.clone())[0].note, "Renamed");
		config.remove_bookmark_ffi(book.clone(), 50, 60);
		assert_eq!(config.get_bookmarks_ffi(book).len(), 1);
		std::fs::remove_dir_all(dir).unwrap();
	}
}
