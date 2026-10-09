//! Rejoins paragraphs that a scan-derived book cut in the middle of a sentence, wherever its page breaks fell.
//!
//! A cut shows as a paragraph that stops without finishing its sentence, followed by one starting in lowercase. Not
//! every such pair is a cut, though: verse, index entries, glossaries, drop caps, and deliberately fragmented prose
//! all look the same line by line. What tells a cut apart is what a printed page does to a paragraph. The paragraph's
//! first printed line is a full line, so the piece before a cut is never a stub; and the last piece finishes the
//! paragraph, so it ends a sentence. Runs of short lines broken at commas are verse, which no page break produces.

use crate::{
	document::{Document, Edit, MarkerType, TocItem},
	util::text::ch_width,
};

/// The shortest piece that can start a cut paragraph: shorter than any full printed line.
const MIN_FIRST_PIECE: usize = 40;
/// A piece at least this long is prose, whatever its ending.
const LONG_PIECE: usize = 100;
const SENTENCE_END: &[char] = &['.', '!', '?', ':', ';', '\u{2026}', '*'];
/// Closing quotes and brackets that may follow a sentence's last mark. Alone, they end index entries and list items.
const CLOSERS: &[char] = &['"', '\'', '\u{201D}', '\u{2019}', '\u{00BB}', ')', ']'];
/// Formats made of books, where scans come from. Every other format's line breaks are kept as its parser left them:
/// PDF rebuilds its own paragraphs, and text, code, and manual pages break lines on purpose. Books with recorded audio
/// are left alone too, since the audio is bound to the text's positions.
const BOOK_FORMATS: &[&str] = &[
	paperback_formats::EPUB.name,
	paperback_formats::WORD.name,
	paperback_formats::DAISY.name,
	paperback_formats::MOBI.name,
	paperback_formats::FB2.name,
];

struct Line<'a> {
	text: &'a str,
	/// Display position of the newline ending this line.
	newline: usize,
	/// Set when the line holds structure a join must not cross: a heading, list, table, image, and the like.
	blocked: bool,
	/// Set when a section, chapter, or table of contents entry begins here, which nothing joins across.
	starts_section: bool,
}

/// Whether documents of the format a parser was registered for get their cut paragraphs joined.
pub(super) fn repairs(format_name: &str) -> bool {
	BOOK_FORMATS.contains(&format_name)
}

/// Joins every cut paragraph in the document, keeping its markers, ids, and table of contents on the same text.
pub(super) fn join_cut_paragraphs(doc: &mut Document) {
	let edits = find_joins(doc);
	if edits.is_empty() {
		return;
	}
	let outcome = doc.buffer.replace_ranges(edits);
	for position in doc.id_positions.values_mut() {
		*position = outcome.shift(*position);
	}
	shift_toc(&mut doc.toc_items, &|position| outcome.shift(position));
}

fn shift_toc(items: &mut [TocItem], shift: &dyn Fn(usize) -> usize) {
	for item in items {
		item.offset = shift(item.offset);
		shift_toc(&mut item.children, shift);
	}
}

fn find_joins(doc: &Document) -> Vec<Edit> {
	let lines = lines(doc);
	let joinable: Vec<bool> = lines.windows(2).map(|pair| is_cut(&pair[0], &pair[1])).collect();
	let mut edits = Vec::new();
	let mut first = 0;
	while first < joinable.len() {
		if !joinable[first] {
			first += 1;
			continue;
		}
		let mut last = first + 1;
		while last < joinable.len() && joinable[last] {
			last += 1;
		}
		if is_paragraph(&lines[first..=last]) {
			for line in &lines[first..last] {
				let text = if line.text.ends_with('-') || line.text.ends_with(char::is_whitespace) { "" } else { " " };
				edits.push(Edit { start: line.newline, end: line.newline + 1, text: text.to_string() });
			}
		}
		first = last;
	}
	edits
}

fn lines(doc: &Document) -> Vec<Line<'_>> {
	let content = &doc.buffer.content;
	let mut lines = Vec::new();
	let mut starts = Vec::new();
	let mut display = 0;
	let mut line_start = 0;
	starts.push(0);
	for (byte, ch) in content.char_indices() {
		if ch == '\n' {
			lines.push(Line {
				text: &content[line_start..byte],
				newline: display,
				blocked: false,
				starts_section: false,
			});
			line_start = byte + 1;
			starts.push(display + 1);
		}
		display += ch_width(ch);
	}
	lines.push(Line { text: &content[line_start..], newline: display, blocked: false, starts_section: false });
	let line_at = |position: usize| starts.partition_point(|&start| start <= position).saturating_sub(1);
	for marker in &doc.buffer.markers {
		let first = line_at(marker.position);
		match marker.mtype {
			MarkerType::SectionBreak | MarkerType::TocItem => lines[first].starts_section = true,
			MarkerType::PageBreak
			| MarkerType::Link
			| MarkerType::Bold
			| MarkerType::Italic
			| MarkerType::Underline => {}
			_ => {
				let last = line_at(marker.position + marker.length.saturating_sub(1));
				for line in &mut lines[first..=last.max(first)] {
					line.blocked = true;
				}
			}
		}
	}
	let mut toc = Vec::new();
	collect_toc_offsets(&doc.toc_items, &mut toc);
	for offset in toc {
		let line = line_at(offset);
		lines[line].starts_section = true;
	}
	lines
}

fn collect_toc_offsets(items: &[TocItem], out: &mut Vec<usize>) {
	for item in items {
		out.push(item.offset);
		collect_toc_offsets(&item.children, out);
	}
}

/// Whether a line stops mid-sentence and the next carries straight on, as either side of a cut does.
fn is_cut(first: &Line, second: &Line) -> bool {
	// A carriage return left in the text would stay inside the joined paragraph as a line break of its own.
	if first.blocked || second.blocked || second.starts_section || first.text.ends_with('\r') {
		return false;
	}
	let mut ending = first.text.trim_end().chars().rev();
	let open = match ending.next() {
		Some(ch) if ch.is_alphabetic() || matches!(ch, ',' | '\u{2014}' | '\u{2013}') => true,
		// A word broken across lines, and not a rule of hyphens.
		Some('-') => ending.next().is_some_and(char::is_alphabetic),
		_ => false,
	};
	let Some(head) = second.text.chars().next() else { return false };
	open && (head.is_lowercase() || head.is_uppercase() && is_cut_before_capital(first.text, second.text))
}

/// Whether a line is cut before a capitalized word, a name or "I", which is also how a heading, a caption, or an
/// unpunctuated voice ends before the next paragraph. Only a piece that is plainly running prose counts: longer than
/// any heading, already holding a finished sentence, and stopping on a lowercase letter, outside any inline table.
fn is_cut_before_capital(first: &str, second: &str) -> bool {
	let first = first.trim_end();
	let finished_sentence = first.char_indices().any(|(at, ch)| {
		matches!(ch, '.' | '!' | '?')
			&& first[at + ch.len_utf8()..]
				.trim_start_matches(['"', '\u{201D}', '\u{2019}'])
				.starts_with(char::is_whitespace)
	});
	first.chars().count() >= LONG_PIECE
		&& first.ends_with(char::is_lowercase)
		&& finished_sentence
		&& !first.contains('\t')
		&& !second.contains('\t')
}

/// Whether a run of lines, each carrying on into the next, is one paragraph a printed page cut rather than verse, an
/// index, or prose that is fragmented on purpose.
fn is_paragraph(pieces: &[Line]) -> bool {
	let length = |line: &Line| line.text.trim_end().chars().count();
	let (first, last) = (&pieces[0], &pieces[pieces.len() - 1]);
	if length(first) < MIN_FIRST_PIECE {
		return false;
	}
	if !ends_sentence(last.text) && length(last) < LONG_PIECE {
		return false;
	}
	let middle = &pieces[1..pieces.len() - 1];
	let breaks = &pieces[..pieces.len() - 1];
	let at_commas = breaks.iter().filter(|line| line.text.trim_end().ends_with([',', '\u{2014}'])).count();
	let verse =
		!middle.is_empty() && middle.iter().all(|line| length(line) < LONG_PIECE) && at_commas * 2 >= breaks.len();
	!verse
}

/// Whether text finishes a sentence, allowing for a bare note number after it.
fn ends_sentence(text: &str) -> bool {
	let text = text.trim_end();
	let before_note = text.trim_end_matches(|ch: char| ch.is_ascii_digit());
	before_note.trim_end_matches(CLOSERS).ends_with(SENTENCE_END)
		&& (before_note.len() == text.len() || !before_note.ends_with(char::is_whitespace))
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::document::{DocumentBuffer, Marker};

	const FIRST: &str = "The women who went to bed with him that night in the house of";
	const SECOND: &str = "the widow brought him naked into the dance and he never forgot it.";

	fn doc(content: &str) -> Document {
		let mut doc = Document::new();
		doc.set_buffer(DocumentBuffer::with_content(content.to_string()));
		doc
	}

	fn joined(content: &str) -> String {
		let mut doc = doc(content);
		join_cut_paragraphs(&mut doc);
		doc.buffer.content
	}

	#[test]
	fn a_paragraph_cut_mid_sentence_is_joined_with_a_space() {
		assert_eq!(joined(&format!("{FIRST}\n{SECOND}\nNext.")), format!("{FIRST} {SECOND}\nNext."));
	}

	#[test]
	fn a_word_hyphenated_across_the_cut_joins_without_a_space() {
		let first = "He had been around the world sixty-five times, and every time well-";
		assert_eq!(joined(&format!("{first}\nknown faces met him.\n")), format!("{first}known faces met him.\n"));
	}

	#[test]
	fn only_book_formats_are_repaired() {
		assert!(repairs(paperback_formats::EPUB.name));
		assert!(repairs(paperback_formats::WORD.name));
		for format in [
			&paperback_formats::PDF,
			&paperback_formats::TEXT,
			&paperback_formats::MARKDOWN,
			&paperback_formats::HTML,
			&paperback_formats::RTF,
			&paperback_formats::MAN,
		] {
			assert!(!repairs(format.name), "{}", format.name);
		}
	}

	#[test]
	fn a_list_ending_in_brackets_is_not_a_finished_sentence() {
		let content = "There are only four things we do better than anyone else in the world today\nmusic\nmicrocode (software)\n";
		assert_eq!(joined(content), content);
	}

	#[test]
	fn a_carriage_return_is_never_left_inside_a_joined_paragraph() {
		let content = format!("{FIRST}\r\n{SECOND}");
		assert_eq!(joined(&content), content);
	}

	#[test]
	fn running_prose_cut_before_a_name_is_joined() {
		let first =
			"He came back in the rain. Dozens of strangers came through the town that week, and nobody noticed when";
		let second = "Aureliano went out to meet them.";
		assert_eq!(joined(&format!("{first}\n{second}")), format!("{first} {second}"));
	}

	#[test]
	fn a_heading_or_unpunctuated_voice_before_a_capital_is_left_alone() {
		for first in [
			"The Albatross came to the South-Western Halls in the year I named the Constellations and counted the Dead",
			"help me someone please help me let me out let me speak let me die let me be something more than this now",
		] {
			let content = format!("{first}\nHolsten sent his reply.");
			assert_eq!(joined(&content), content);
		}
	}

	#[test]
	fn a_paragraph_that_finished_its_sentence_is_left_alone() {
		let content = format!("{FIRST} her.\n{SECOND}\n");
		assert_eq!(joined(&content), content);
	}

	#[test]
	fn a_capitalized_next_paragraph_is_left_alone() {
		let content = format!("{FIRST}\nThe widow said nothing at all.\n");
		assert_eq!(joined(&content), content);
	}

	#[test]
	fn a_long_cut_paragraph_joins_across_several_pages() {
		let middle =
			"page after page of the same long sentence, which goes on and on through the whole of a printed page";
		assert_eq!(joined(&format!("{FIRST}\n{middle}\n{SECOND}")), format!("{FIRST} {middle} {SECOND}"));
	}

	#[test]
	fn drop_caps_index_terms_and_glossary_words_are_too_short_to_start_a_cut() {
		for content in [
			"I\nn the early morning hours they left.",
			"digging stick\ndiplomacy, 32.",
			"Latinos\nan umbrella term for people.",
		] {
			assert_eq!(joined(content), content);
		}
	}

	#[test]
	fn an_index_entry_that_ends_without_finishing_a_sentence_is_left_alone() {
		let content = "National Museum of Anthropology, see museums\nneedles, bronze\n";
		assert_eq!(joined(content), content);
	}

	#[test]
	fn index_entries_ending_in_page_numbers_are_left_alone() {
		let content = "consequences of the conquest for the people of the valley, 132\neconomic devastation and, 132\n";
		assert_eq!(joined(content), content);
	}

	#[test]
	fn a_note_number_after_the_last_sentence_still_ends_it() {
		let second = "the widow brought him naked into the dance.23";
		assert_eq!(joined(&format!("{FIRST}\n{second}")), format!("{FIRST} {second}"));
	}

	#[test]
	fn a_stanza_broken_at_commas_is_verse() {
		let content = "In the beginning when the word was spoken over the river,\nin the beginning when the fire was lighted,\nin the beginning when the house was built,\nwe were among you.";
		assert_eq!(joined(content), content);
	}

	#[test]
	fn no_join_crosses_a_heading_list_or_table() {
		for mtype in [MarkerType::Heading2, MarkerType::ListItem, MarkerType::Table] {
			let mut doc = doc(&format!("{FIRST}\n{SECOND}"));
			doc.buffer.add_marker(Marker::new(mtype, FIRST.len() + 1).with_length(SECOND.len()));
			join_cut_paragraphs(&mut doc);
			assert!(doc.buffer.content.contains('\n'), "{mtype:?}");
		}
	}

	#[test]
	fn no_join_crosses_a_section_or_table_of_contents_entry() {
		let mut doc = doc(&format!("{FIRST}\n{SECOND}"));
		doc.buffer.add_marker(Marker::new(MarkerType::SectionBreak, FIRST.len() + 1));
		join_cut_paragraphs(&mut doc);
		assert!(doc.buffer.content.contains('\n'));
		let mut doc = doc_with_toc(FIRST.len() + 1);
		join_cut_paragraphs(&mut doc);
		assert!(doc.buffer.content.contains('\n'));
	}

	fn doc_with_toc(offset: usize) -> Document {
		let mut doc = doc(&format!("{FIRST}\n{SECOND}"));
		doc.toc_items = vec![TocItem::new("Two".to_string(), String::new(), offset)];
		doc
	}

	#[test]
	fn a_page_break_between_the_pieces_stays_inside_the_joined_paragraph() {
		let mut doc = doc(&format!("{FIRST}\n{SECOND}"));
		doc.buffer.add_marker(Marker::new(MarkerType::PageBreak, FIRST.len() + 1).with_text("12".to_string()));
		join_cut_paragraphs(&mut doc);
		assert_eq!(doc.buffer.content, format!("{FIRST} {SECOND}"));
		assert_eq!(doc.buffer.markers[0].position, FIRST.len() + 1);
	}

	#[test]
	fn positions_after_a_hyphen_join_move_back_with_their_text() {
		let first = "He had been around the world sixty-five times, and every time well-";
		let mut doc = doc(&format!("{first}\nknown faces met him.\nChapter two"));
		let chapter = first.len() + 22;
		doc.buffer.add_marker(Marker::new(MarkerType::Heading1, chapter).with_length(11));
		doc.id_positions.insert("two".to_string(), chapter);
		doc.toc_items = vec![TocItem::new("Two".to_string(), "two".to_string(), chapter)];
		join_cut_paragraphs(&mut doc);
		let expected = doc.buffer.content.find("Chapter").unwrap();
		assert_eq!(doc.buffer.markers[0].position, expected);
		assert_eq!(doc.id_positions["two"], expected);
		assert_eq!(doc.toc_items[0].offset, expected);
	}

	/// A book from the fixture folder, which only some machines have; tests using one pass without it.
	fn fixture(name: &str) -> Option<crate::document::ParserContext> {
		let path = std::path::Path::new(&std::env::var_os("HOME")?).join("Documents/home/books").join(name);
		path.is_file().then(|| crate::document::ParserContext::new(path.to_string_lossy().into_owned()))
	}

	/// The book's text as its parser left it, and as it reads with cut paragraphs joined.
	fn before_and_after(name: &str) -> Option<(String, String)> {
		let context = fixture(name)?;
		let parser = super::super::ParserRegistry::global().get_parsers_for_extension("epub")[0];
		let before = parser.parse(&context).expect("parse fixture").buffer.content;
		let after = super::super::parse_document(&context).expect("parse fixture").buffer.content;
		Some((before, after))
	}

	#[test]
	fn one_hundred_years_of_solitude_has_every_cut_joined() {
		let Some((before, after)) = before_and_after("One_Hundred_Years_of_Solitude_rashad_naqeeb.epub") else {
			return;
		};
		assert_eq!(before.lines().count() - after.lines().count(), 317);
		let mut joined = doc(&after);
		join_cut_paragraphs(&mut joined);
		assert_eq!(joined.buffer.content, after, "a second pass finds nothing left to join");
	}

	#[test]
	fn well_made_books_are_left_as_they_were() {
		for name in [
			"The_Prize_rashad_naqeeb.epub",
			"Revelation_Space_rashad_naqeeb.epub",
			"The_Word_for_World_is_Forest_rashad_naqeeb.epub",
		] {
			let Some((before, after)) = before_and_after(name) else { continue };
			assert!(before == after, "{name} changed");
		}
	}
}
