//! The fork's sync on the desktop (paperback-core's `config::manager::fork_sync`): where the sync
//! folder is, and moving open books to where another device left them.

use std::{
	env,
	path::{Path, PathBuf},
};

use paperback_core::config::ConfigManager;

use super::{DocumentManager, move_to_offset_and_record_history, persist_navigation_history};

/// `PAPERBACK_SYNC_DIR` when set, otherwise Paperback Sync inside iCloud Drive's books folder,
/// where the iPhone app reaches it through the access it already has to the books. Only on the
/// Mac, the one desktop the fork is for.
fn sync_folder() -> Option<PathBuf> {
	if !cfg!(target_os = "macos") {
		return None;
	}
	if let Some(folder) = env::var_os("PAPERBACK_SYNC_DIR") {
		return Some(folder.into());
	}
	let books = PathBuf::from(env::var_os("HOME")?).join("Library/Mobile Documents/com~apple~CloudDocs/books");
	books.is_dir().then(|| books.join("Paperback Sync"))
}

pub fn configure_sync(config: &ConfigManager) {
	if let Some(folder) = sync_folder() {
		config.sync_configure(&folder, "mac");
	}
}

impl DocumentManager {
	/// Moves each open book another device has read since to where it was left, for when Paperback
	/// comes back to the front. Recorded as a jump, so going back returns to where this Mac was.
	pub fn take_synced_positions(&mut self) {
		let moves = self.config.lock().unwrap().sync_pull();
		for (path, position) in moves {
			let Some(index) = self.find_tab_by_path(Path::new(&path)) else { continue };
			let tab = &mut self.tabs[index];
			let update = move_to_offset_and_record_history(tab, position);
			persist_navigation_history(&self.config, tab.track.then_some(&update));
		}
		self.update_status_bar();
	}

	/// Saves a move the position throttle held back, so the other devices get the last place read.
	pub fn save_unsaved_position(&self) {
		if self.position_unsaved.get() {
			self.last_position_save.set(None);
			self.save_position_throttled();
		}
	}
}
