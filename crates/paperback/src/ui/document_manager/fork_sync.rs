//! The fork's sync on the desktop (paperback-core's `config::manager::fork_sync`): Apple's iCloud
//! key-value store as the place it syncs through, and a timer that sends the reader's place to the
//! other devices and takes theirs.
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

use paperback_core::{config::ConfigManager, session::DocumentSession};
use wxdragon::{prelude::*, timer::Timer};

use super::{DocumentManager, move_to_offset_and_record_history, parse_settings, persist_navigation_history};

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

/// Starts sync through iCloud, on the Mac only, the one desktop the fork is for. Off for a scratch
/// `PAPERBACK_CONFIG_DIR`, whose blank settings are no place to sync from. The store only reaches
/// iCloud from the signed app bundle (`macos-signing/build-app.sh`), which carries the entitlement.
pub fn configure_sync(config: &ConfigManager) {
	#[cfg(target_os = "macos")]
	if env::var_os("PAPERBACK_CONFIG_DIR").is_none() {
		let store = icloud::ICloudStore::new();
		let devices: Vec<(String, usize)> = paperback_core::config::SyncStore::keys(&store)
			.into_iter()
			.map(|key| {
				let bytes = paperback_core::config::SyncStore::get(&store, key.clone()).map_or(0, |value| value.len());
				(key, bytes)
			})
			.collect();
		tracing::info!(?devices, "sync through iCloud started");
		config.sync_start("mac", std::sync::Arc::new(store));
	}
	#[cfg(not(target_os = "macos"))]
	let _ = config;
}

#[cfg(target_os = "macos")]
mod icloud {
	use std::{
		ffi::{CStr, CString, c_char},
		ptr,
	};

	use objc::{class, msg_send, runtime::Object, sel, sel_impl};
	use paperback_core::config::SyncStore;

	/// `NSUbiquitousKeyValueStore`, which the iPhone app shares by naming the same store in its
	/// entitlements.
	pub struct ICloudStore;

	impl ICloudStore {
		pub fn new() -> Self {
			// Picks up what iCloud brought while the app was not running.
			let _: bool = unsafe { msg_send![store(), synchronize] };
			Self
		}
	}

	fn store() -> *mut Object {
		unsafe { msg_send![class!(NSUbiquitousKeyValueStore), defaultStore] }
	}

	fn ns_string(text: &str) -> *mut Object {
		let Ok(text) = CString::new(text) else { return ptr::null_mut() };
		unsafe { msg_send![class!(NSString), stringWithUTF8String: text.as_ptr()] }
	}

	/// # Safety
	///
	/// `string` is null or a live `NSString`.
	unsafe fn rust_string(string: *mut Object) -> Option<String> {
		if string.is_null() {
			return None;
		}
		let utf8: *const c_char = unsafe { msg_send![string, UTF8String] };
		(!utf8.is_null()).then(|| unsafe { CStr::from_ptr(utf8) }.to_string_lossy().into_owned())
	}

	// Called on the UI thread only, inside the event loop's autorelease pool.
	impl SyncStore for ICloudStore {
		fn get(&self, key: String) -> Option<String> {
			let value: *mut Object = unsafe { msg_send![store(), stringForKey: ns_string(&key)] };
			unsafe { rust_string(value) }
		}

		fn set(&self, key: String, value: String) {
			tracing::debug!(key, bytes = value.len(), "wrote this Mac's places to iCloud");
			let _: () = unsafe { msg_send![store(), setString: ns_string(&value) forKey: ns_string(&key)] };
		}

		fn keys(&self) -> Vec<String> {
			unsafe {
				let dictionary: *mut Object = msg_send![store(), dictionaryRepresentation];
				let keys: *mut Object = msg_send![dictionary, allKeys];
				let count: usize = msg_send![keys, count];
				(0..count)
					.filter_map(|index| {
						let key: *mut Object = msg_send![keys, objectAtIndex: index];
						rust_string(key)
					})
					.collect()
			}
		}
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
	/// Books with a saved place that sync has not seen yet, offered to the other devices one per
	/// tick; `None` until the first tick lists them.
	unseen: Option<Vec<String>>,
}

impl SyncWatch {
	pub const fn new() -> Self {
		Self { caret: None, front: None, last_pull: None, lengths: BTreeMap::new(), unseen: None }
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
			let started = timer.start(TICK_MS, false);
			tracing::info!(started, "sync timer");
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
		offer_one_saved_place(&config, &mut watch);
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
		tracing::info!(books = moves.len(), "took newer places from another device");
		for (path, position) in moves {
			let Some(index) = self.find_tab_by_path(Path::new(&path)) else { continue };
			let tab = &mut self.tabs[index];
			let update = move_to_offset_and_record_history(tab, position);
			persist_navigation_history(&self.config, tab.track.then_some(&update));
		}
		self.update_status_bar();
	}
}

/// Every book the config has a place for goes to the other devices, not only those opened since
/// sync began: the first run after sync arrived carries the places read before it. One book per
/// tick, since each has to be parsed to convert its place, and parsing them all at once would
/// hold the window up.
fn offer_one_saved_place(config: &ConfigManager, watch: &mut SyncWatch) {
	let unseen = watch.unseen.get_or_insert_with(|| {
		let unseen: Vec<String> = config
			.get_all_documents()
			.into_iter()
			.filter(|path| config.get_document_position(path) > 0 || !config.get_bookmarks(path).is_empty())
			.collect();
		tracing::info!(books = unseen.len(), "offering saved places to sync");
		unseen
	});
	while let Some(path) = unseen.pop() {
		if !Path::new(&path).is_file() || config.sync_knows(&path) {
			tracing::debug!(
				path,
				file = Path::new(&path).is_file(),
				known = config.sync_knows(&path),
				"saved place skipped"
			);
			continue;
		}
		let password = config.get_document_password(&path);
		let format = config.get_document_format(&path);
		if let Ok(session) = DocumentSession::new(&path, &password, &format, parse_settings(config)) {
			config.sync_open(&path, session.handle().document());
			config.flush();
			tracing::info!(path, "offered a saved place to sync");
		}
		return;
	}
}
