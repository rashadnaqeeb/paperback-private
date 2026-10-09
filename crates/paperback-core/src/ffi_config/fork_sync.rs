//! Sync for the fork's iPhone app (`config::manager::fork_sync`).

use std::{path::Path, sync::Arc};

use super::ConfigManagerFfi;
use crate::session::DocumentSession;

/// A book whose position another device moved, and where to.
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncMoveFfi {
	pub path: String,
	pub position: i64,
}

// Owned parameters because that is the signature UniFFI generates for.
#[allow(clippy::needless_pass_by_value)]
#[cfg_attr(feature = "uniffi", uniffi::export)]
impl ConfigManagerFfi {
	pub fn sync_configure_ffi(&self, folder: String, device: String) {
		self.inner.lock().unwrap().sync_configure(Path::new(&folder), &device);
	}

	/// Call after parsing a book and before reading its position. True when another device's
	/// position or bookmarks were taken.
	pub fn sync_open_ffi(&self, path: String, session: Arc<DocumentSession>) -> bool {
		self.inner.lock().unwrap().sync_open(&path, session.handle().document())
	}

	pub fn sync_pull_ffi(&self) -> Vec<SyncMoveFfi> {
		self.inner
			.lock()
			.unwrap()
			.sync_pull()
			.into_iter()
			.map(|(path, position)| SyncMoveFfi { path, position })
			.collect()
	}
}
