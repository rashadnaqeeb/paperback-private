//! The fork's sync on the desktop (paperback-core's `config::manager::fork_sync`): where the sync
//! folder is, and a timer that sends the reader's place to the other devices and takes theirs.
//!
//! The timer, not window activation, does the work. Activation also comes and goes with every
//! dialog, and a Mac left with Paperback in front (the screen locked, the reader away at the
//! iPhone) is never deactivated at all. Every lock it takes is a `try_lock`: dialogs run nested
//! event loops whose openers hold the config, and a tick inside one would otherwise wait forever.

use std::{
	collections::BTreeMap,
	env,
	path::{Path, PathBuf},
	rc::Rc,
	sync::Mutex,
	time::{Duration, Instant},
};

use paperback_core::config::ConfigManager;
use wxdragon::{prelude::*, timer::Timer};

use super::{DocumentManager, move_to_offset_and_record_history, persist_navigation_history};

const TICK_MS: i32 = 2000;
/// How long the caret stays put before its place is sent. Long enough to pass over the places a
/// book's caret goes through while it loads, which are not where the reader is.
const RESTED: Duration = Duration::from_secs(3);
/// How long after Paperback comes to the front, if the reader has not moved, to keep looking for
/// the other device's place: iCloud can take a while to bring it.
const WATCH_AFTER_FRONT: Duration = Duration::from_mins(2);
/// How long the caret stays put before the reader counts as away, and another device's newer place
/// may be taken while Paperback is in front.
const AWAY: Duration = Duration::from_mins(2);
const PULL_EVERY: Duration = Duration::from_secs(10);

/// `PAPERBACK_SYNC_DIR` when set, otherwise Paperback Sync inside iCloud Drive's books folder,
/// where the iPhone app reaches it through the access it already has to the books. Off for a
/// scratch `PAPERBACK_CONFIG_DIR` without a sync folder of its own, whose blank settings are no
/// place to sync from, and off everywhere but the Mac, the one desktop the fork is for.
fn sync_folder() -> Option<PathBuf> {
	if !cfg!(target_os = "macos") {
		return None;
	}
	if let Some(folder) = env::var_os("PAPERBACK_SYNC_DIR") {
		return Some(folder.into());
	}
	if env::var_os("PAPERBACK_CONFIG_DIR").is_some() {
		return None;
	}
	let books = PathBuf::from(env::var_os("HOME")?).join("Library/Mobile Documents/com~apple~CloudDocs/books");
	books.is_dir().then(|| books.join("Paperback Sync"))
}

pub fn configure_sync(config: &ConfigManager) {
	if let Some(folder) = sync_folder() {
		config.sync_configure(&folder, "mac");
	}
}

/// What the sync timer remembers between ticks.
pub struct SyncWatch {
	/// The active book, its caret at the last tick, and since when the caret has been there.
	caret: Option<(PathBuf, i64, Instant)>,
	front: Option<Instant>,
	last_pull: Option<Instant>,
	/// Each open book's length as sync last saw it, to notice a book parsed again.
	lengths: BTreeMap<PathBuf, i64>,
}

impl SyncWatch {
	pub const fn new() -> Self {
		Self { caret: None, front: None, last_pull: None, lengths: BTreeMap::new() }
	}
}

impl DocumentManager {
	pub fn sync_timer(
		frame: &Frame,
		doc_manager: &Rc<Mutex<Self>>,
		config: &Rc<Mutex<ConfigManager>>,
	) -> Rc<Timer<Frame>> {
		let timer = Rc::new(Timer::new(frame));
		let dm = Rc::clone(doc_manager);
		timer.on_tick(move |_| {
			if let Ok(mut dm) = dm.try_lock() {
				dm.sync_tick();
			}
		});
		if config.lock().unwrap().sync_enabled() {
			timer.start(TICK_MS, false);
		}
		timer
	}

	#[cfg(target_os = "macos")]
	pub fn came_to_front(&self) {
		self.sync_watch.borrow_mut().front = Some(Instant::now());
	}

	fn sync_tick(&mut self) {
		let Ok(config) = self.config.try_lock() else { return };
		let mut watch = self.sync_watch.borrow_mut();
		// A book parsed again (a reload, a change to how tables show) converts with its new text.
		for tab in &self.tabs {
			let length = tab.session.document_len();
			if watch.lengths.insert(tab.file_path.clone(), length).is_some_and(|old| old != length) {
				config.sync_reparsed(&tab.file_path.to_string_lossy(), tab.session.handle().document());
			}
		}
		let Some(tab) = self.active_tab().filter(|tab| tab.track) else {
			watch.caret = None;
			return;
		};
		let now = Instant::now();
		let caret = tab.window.to_doc(tab.text_ctrl.get_insertion_point());
		let since = match &watch.caret {
			Some((path, at, since)) if *path == tab.file_path && *at == caret => *since,
			_ => now,
		};
		watch.caret = Some((tab.file_path.clone(), caret, since));
		// The save throttle can hold the last move back for good if no key follows it.
		let path = tab.file_path.to_string_lossy();
		if now - since >= RESTED && config.get_document_position(&path) != caret {
			config.set_document_position(&path, caret);
			config.flush();
		}
		let quiet_since_front = watch.front.is_some_and(|front| since <= front && front.elapsed() < WATCH_AFTER_FRONT);
		let away = now - since >= AWAY;
		let due = watch.last_pull.is_none_or(|last| last.elapsed() >= PULL_EVERY);
		if (quiet_since_front || away) && due {
			watch.last_pull = Some(now);
			drop(watch);
			drop(config);
			self.take_synced_positions();
		}
	}

	/// Moves each open book another device has read since to where it was left. Recorded as a jump,
	/// so going back returns to where this Mac was.
	fn take_synced_positions(&mut self) {
		let Ok(config) = self.config.try_lock() else { return };
		let moves = config.sync_pull();
		drop(config);
		if moves.is_empty() {
			return;
		}
		for (path, position) in moves {
			let Some(index) = self.find_tab_by_path(Path::new(&path)) else { continue };
			let tab = &mut self.tabs[index];
			let update = move_to_offset_and_record_history(tab, position);
			persist_navigation_history(&self.config, tab.track.then_some(&update));
		}
		self.update_status_bar();
	}
}
