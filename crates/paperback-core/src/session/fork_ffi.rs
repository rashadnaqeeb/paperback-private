//! What the fork's iPhone reading screen asks of a document beyond upstream's calls: the book's
//! structure in one pass, and every match of a search for the in-book results list.

use super::{DocumentSession, LineMarker, SearchOptionsFfi};
use crate::{document::MarkerType, reader_core::SearchOptions};

/// One line holding a match: its text, its page (`0` when the book has none), and where the
/// line's first match starts.
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FindAllLineFfi {
	pub text: String,
	pub page: i32,
	pub position: i64,
}

#[cfg_attr(feature = "uniffi", uniffi::export)]
impl DocumentSession {
	/// Every marker but character formatting, in buffer order. Asking per line instead scans the
	/// marker list once per line, which on a whole book is lines times markers.
	#[must_use]
	pub fn get_structure_markers_ffi(&self) -> Vec<LineMarker> {
		self.handle
			.document()
			.buffer
			.markers
			.iter()
			.filter(|m| !matches!(m.mtype, MarkerType::Bold | MarkerType::Italic | MarkerType::Underline))
			.map(|m| LineMarker {
				mtype: m.mtype,
				position: i64::try_from(m.position).unwrap_or(0),
				text: m.text.clone(),
				reference: m.reference.clone(),
				level: m.level,
				length: i64::try_from(m.length).unwrap_or(0),
			})
			.collect()
	}

	// `query: String` (not `&str`) because that is the signature UniFFI generates for.
	#[must_use]
	#[allow(clippy::needless_pass_by_value)]
	pub fn find_all_ffi(&self, query: String, options: SearchOptionsFfi) -> Vec<FindAllLineFfi> {
		let mut search_options = SearchOptions::empty();
		if options.match_case {
			search_options.insert(SearchOptions::MATCH_CASE);
		}
		if options.whole_word {
			search_options.insert(SearchOptions::WHOLE_WORD);
		}
		if options.regex {
			search_options.insert(SearchOptions::REGEX);
		}
		self.find_all_lines(&query, search_options)
			.into_iter()
			.filter_map(|line| {
				let position = line.matches.first()?.start;
				Some(FindAllLineFfi { text: line.text, page: line.page, position })
			})
			.collect()
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::document::{Document, DocumentBuffer, DocumentHandle, Marker, ParserFlags};

	fn session(content: &str, markers: Vec<Marker>) -> DocumentSession {
		let mut buffer = DocumentBuffer::with_content(content.to_string());
		for marker in markers {
			buffer.add_marker(marker);
		}
		let mut doc = Document::new();
		doc.set_buffer(buffer);
		DocumentSession {
			handle: DocumentHandle::new(doc),
			file_path: "book.epub".to_string(),
			history: Vec::new(),
			history_index: 0,
			parser_flags: ParserFlags::empty(),
		}
	}

	#[test]
	fn structure_markers_leave_out_formatting_and_keep_buffer_order() {
		let link =
			Marker { text: "here".to_string(), reference: "#n1".to_string(), ..Marker::new(MarkerType::Link, 12) };
		let session = session(
			"Chapter One\nClick here now.\n",
			vec![link, Marker::new(MarkerType::Bold, 18), Marker { level: 1, ..Marker::new(MarkerType::Heading1, 0) }],
		);
		let markers = session.get_structure_markers_ffi();
		let types: Vec<MarkerType> = markers.iter().map(|m| m.mtype).collect();
		assert_eq!(types, vec![MarkerType::Heading1, MarkerType::Link]);
		assert_eq!(markers[1].position, 12);
		assert_eq!(markers[1].text, "here");
		assert_eq!(markers[1].reference, "#n1");
	}

	#[test]
	fn find_all_gives_each_lines_first_match() {
		let session = session("alpha beta beta\ngamma\ndelta beta\n", Vec::new());
		let options = SearchOptionsFfi { match_case: false, whole_word: false, regex: false, forward: true };
		let rows = session.find_all_ffi("beta".to_string(), options);
		assert_eq!(rows.len(), 2);
		assert_eq!(rows[0], FindAllLineFfi { text: "alpha beta beta".to_string(), page: 0, position: 6 });
		assert_eq!(rows[1].position, 28);
	}
}
