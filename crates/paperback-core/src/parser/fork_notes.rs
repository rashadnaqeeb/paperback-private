//! Links the bare note numbers of a scan-derived book to its notes, and each note back.
//!
//! Well-made books link a note reference to its note. Scan-derived ones often carry the reference as a number stuck to
//! the end of a word or sentence ("to Europe.1") and the notes as numbered paragraphs under a Notes heading near the
//! end, grouped by chapter and counting from 1 in each. The numbers in the text count the same way, so lining up the
//! numbers found in the text against the notes, in order, puts each reference with its note. Numbers that are not
//! references (a figure, a year, a decimal) find no place in the line-up and are left alone, and so is a book whose
//! numbers mostly fail to line up, since a wrong link is worse than none.

use crate::{
	document::{Document, Marker, MarkerType},
	util::text::ch_width,
};

const NOTES_HEADINGS: &[&str] = &["notes", "endnotes", "end notes", "notes and sources", "source notes"];
/// Punctuation that can stand between a word and its note number: a clause's or a quotation's closing marks.
const BEFORE_NUMBER: &[char] = &['.', ',', ';', ':', '!', '?', ')', '"', '\'', '\u{201D}', '\u{2019}', '\u{2026}'];
/// Numbers the notes can skip over within a group, for a note the scan lost.
const MAX_GAP: u32 = 3;
/// The largest line-up worth working out, in candidate numbers times notes (16 MB of working memory); beyond it the
/// book is left alone.
const MAX_CELLS: usize = 8_000_000;

struct Line<'a> {
	text: &'a str,
	/// Display position of the line's first character.
	start: usize,
	heading: Option<i32>,
}

/// A number in the text that may be a note reference: its value, where its digits start, and whether it sits where
/// only a reference would (after a word) or could also be part of something else (after a number, as in "1921.39").
struct Reference {
	number: u32,
	start: usize,
	digits: String,
	clear: bool,
}

/// A numbered note: its group, its number, and where the number starts.
struct Note {
	group: usize,
	number: u32,
	start: usize,
	digits: String,
}

fn is_vague(marker: &Marker) -> bool {
	!marker.reference.contains('#')
}

/// Links every bare note number to its note, returning how many it linked.
pub(super) fn link_bare_notes(doc: &mut Document) -> usize {
	let Some((references, notes, matches)) = plan(doc) else { return 0 };
	let replaced: Vec<usize> = matches.iter().map(|&(reference, _)| references[reference].start).collect();
	doc.buffer.markers.retain(|marker| {
		!(marker.mtype == MarkerType::Link && is_vague(marker) && replaced.binary_search(&marker.position).is_ok())
	});
	for &(reference, note) in &matches {
		let (reference, note) = (&references[reference], &notes[note]);
		let note_id = format!("pb-note-{}-{}", note.group, note.number);
		let reference_id = format!("pb-ref-{}-{}", note.group, note.number);
		doc.id_positions.insert(note_id.clone(), note.start);
		doc.id_positions.insert(reference_id.clone(), reference.start);
		doc.buffer.add_marker(link(reference.start, &reference.digits, &note_id));
		doc.buffer.add_marker(link(note.start, &note.digits, &reference_id));
	}
	matches.len()
}

/// The candidate references, the notes, and which reference goes with which note.
fn plan(doc: &Document) -> Option<(Vec<Reference>, Vec<Note>, Vec<(usize, usize)>)> {
	let lines = lines(doc);
	let notes_line = notes_heading(&lines)?;
	let notes: Vec<Note> = note_groups(&lines, notes_line).into_iter().flatten().collect();
	let references = candidates(doc, &lines[..notes_line]);
	let matches = line_up(&references, &notes)?;
	Some((references, notes, matches))
}

fn link(position: usize, digits: &str, target: &str) -> Marker {
	let mut marker = Marker::new(MarkerType::Link, position);
	marker.text = digits.to_string();
	marker.reference = format!("#{target}");
	marker.length = digits.chars().map(ch_width).sum();
	marker
}

fn lines(doc: &Document) -> Vec<Line<'_>> {
	let content = &doc.buffer.content;
	let mut lines = Vec::new();
	let mut display = 0;
	let mut line_start = 0;
	let mut line_display = 0;
	for (byte, ch) in content.char_indices() {
		if ch == '\n' {
			lines.push(Line { text: &content[line_start..byte], start: line_display, heading: None });
			line_start = byte + 1;
			line_display = display + 1;
		}
		display += ch_width(ch);
	}
	lines.push(Line { text: &content[line_start..], start: line_display, heading: None });
	for marker in &doc.buffer.markers {
		let level = match marker.mtype {
			MarkerType::Heading1 => 1,
			MarkerType::Heading2 => 2,
			MarkerType::Heading3 => 3,
			MarkerType::Heading4 => 4,
			MarkerType::Heading5 => 5,
			MarkerType::Heading6 => 6,
			_ => continue,
		};
		let index = lines.partition_point(|line| line.start <= marker.position).saturating_sub(1);
		lines[index].heading = Some(level);
	}
	lines
}

/// The line reading "Notes" that the notes follow, and not the same word in a table of contents: its next lines are
/// a note numbered 1, perhaps after a chapter's title.
fn notes_heading(lines: &[Line]) -> Option<usize> {
	(0..lines.len()).rev().find(|&index| {
		NOTES_HEADINGS.contains(&lines[index].text.trim().to_lowercase().as_str())
			&& lines[index + 1..]
				.iter()
				.filter(|line| !line.text.trim().is_empty())
				.take(3)
				.any(|line| note_number(line.text).is_some_and(|(number, _)| number == 1))
	})
}

/// The note number starting a line ("12. Seymour, p. 9."), and its digits.
fn note_number(text: &str) -> Option<(u32, &str)> {
	let text = text.trim_start();
	let end = text.find(|ch: char| !ch.is_ascii_digit())?;
	let digits = &text[..end];
	if digits.is_empty() || digits.len() > 3 {
		return None;
	}
	let rest = &text[end..];
	let rest = rest.strip_prefix('.').unwrap_or(rest);
	if !rest.starts_with(char::is_whitespace) {
		return None;
	}
	Some((digits.parse().ok()?, digits))
}

/// The notes under the heading, split into groups wherever the numbering starts again at 1. The notes end at the next
/// heading as high as theirs.
fn note_groups(lines: &[Line], notes_line: usize) -> Vec<Vec<Note>> {
	let level = lines[notes_line].heading.unwrap_or(1);
	let mut groups: Vec<Vec<Note>> = Vec::new();
	for line in &lines[notes_line + 1..] {
		if line.heading.is_some_and(|heading| heading <= level) {
			break;
		}
		let Some((number, digits)) = note_number(line.text) else { continue };
		let leading = line.text.len() - line.text.trim_start().len();
		let note = Note {
			group: 0,
			number,
			start: line.start + line.text[..leading].chars().map(ch_width).sum::<usize>(),
			digits: digits.to_string(),
		};
		match groups.last_mut() {
			Some(group)
				if number != 1
					&& group.last().is_some_and(|last| number > last.number && number <= last.number + MAX_GAP) =>
			{
				group.push(note);
			}
			_ if number == 1 => groups.push(vec![note]),
			_ => {}
		}
	}
	for (index, group) in groups.iter_mut().enumerate() {
		for note in group {
			note.group = index;
		}
	}
	groups
}

/// The numbers in the text before the notes that may be references, in reading order, leaving out headings and
/// numbers the book already links to a place. A link to a whole file, which some Word books put on note numbers,
/// lands nowhere near the note, so its number is taken like a bare one.
fn candidates(doc: &Document, lines: &[Line]) -> Vec<Reference> {
	let links: Vec<(usize, usize)> = doc
		.buffer
		.markers
		.iter()
		.filter(|marker| marker.mtype == MarkerType::Link && !is_vague(marker))
		.map(|marker| (marker.position, marker.position + marker.length.max(1)))
		.collect();
	lines
		.iter()
		.filter(|line| line.heading.is_none())
		.flat_map(references)
		.filter(|reference| !links.iter().any(|&(start, end)| reference.start >= start && reference.start < end))
		.collect()
}

/// The numbers in a line that sit where a note number does: one to three digits before a space, a closing bracket, or
/// the line's end, after a word, either straight after its last letter or after the punctuation closing it (up to
/// three marks, with a space before or after them). "By 12 points" is not one: a number after a space has to follow
/// punctuation. After a number and punctuation ("April 22.22") it may be a reference or a decimal, which the line-up
/// settles.
fn references(line: &Line) -> Vec<Reference> {
	let chars: Vec<char> = line.text.chars().collect();
	let mut found = Vec::new();
	let mut display = line.start;
	let mut index = 0;
	while index < chars.len() {
		if !chars[index].is_ascii_digit() {
			display += ch_width(chars[index]);
			index += 1;
			continue;
		}
		let start = index;
		let start_display = display;
		while index < chars.len() && chars[index].is_ascii_digit() {
			display += 1;
			index += 1;
		}
		let digits: String = chars[start..index].iter().collect();
		let after_ok = index == chars.len() || chars[index].is_whitespace() || matches!(chars[index], ')' | ']');
		let mut before = start;
		let spaced_after_marks = before > 0 && chars[before - 1] == ' ';
		if spaced_after_marks {
			before -= 1;
		}
		let mut marks = 0;
		while marks < 3 && before > 0 && BEFORE_NUMBER.contains(&chars[before - 1]) {
			before -= 1;
			marks += 1;
		}
		if marks > 0 && before > 0 && chars[before - 1] == ' ' {
			before -= 1;
		}
		let word = before > 0 && chars[before - 1].is_alphabetic();
		let number = before > 0 && chars[before - 1].is_ascii_digit() && marks > 0;
		let placed = (word || number) && (marks > 0 || !spaced_after_marks);
		if digits.len() <= 3
			&& after_ok
			&& placed
			&& let Ok(value) = digits.parse()
		{
			found.push(Reference { number: value, start: start_display, digits, clear: word });
		}
	}
	found
}

/// Lines the candidate references up against the notes, in order, matching equal numbers: the line-up matching the
/// most, preferring clear references to ones after a number. None when it matches under a quarter of the notes or
/// under half of the clear references, which says the book is not laid out the way this expects, or links its notes
/// already.
fn line_up(references: &[Reference], notes: &[Note]) -> Option<Vec<(usize, usize)>> {
	let (rows, columns) = (references.len(), notes.len());
	// Two points a match at most, so the counts fit 16 bits for any book within the cell limit.
	if rows == 0 || columns == 0 || (rows + 1) * (columns + 1) > MAX_CELLS || columns > usize::from(u16::MAX) / 2 {
		return None;
	}
	let weight = |reference: &Reference| if reference.clear { 2 } else { 1 };
	let mut best = vec![0_u16; (rows + 1) * (columns + 1)];
	let cell = |row: usize, column: usize| row * (columns + 1) + column;
	for row in 1..=rows {
		for column in 1..=columns {
			let mut value = best[cell(row - 1, column)].max(best[cell(row, column - 1)]);
			if references[row - 1].number == notes[column - 1].number {
				value = value.max(best[cell(row - 1, column - 1)] + weight(&references[row - 1]));
			}
			best[cell(row, column)] = value;
		}
	}
	let mut matches = Vec::new();
	let (mut row, mut column) = (rows, columns);
	while row > 0 && column > 0 {
		if best[cell(row, column)] == best[cell(row - 1, column)] {
			row -= 1;
		} else if best[cell(row, column)] == best[cell(row, column - 1)] {
			column -= 1;
		} else {
			matches.push((row - 1, column - 1));
			row -= 1;
			column -= 1;
		}
	}
	matches.reverse();
	let clear = references.iter().filter(|reference| reference.clear).count();
	let clear_matched = matches.iter().filter(|&&(reference, _)| references[reference].clear).count();
	(matches.len() * 4 >= columns && clear_matched * 2 >= clear).then_some(matches)
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::document::DocumentBuffer;

	fn doc(content: &str) -> Document {
		let mut doc = Document::new();
		doc.set_buffer(DocumentBuffer::with_content(content.to_string()));
		doc
	}

	const BOOK: &str = "Chapter One\nWilson sailed for Europe.1 The crowds were vast.2\nHe met them all.3\n\
		Chapter Two\nParis was cold.1 Clemenceau was not.2\nNotes\nCHAPTER 1: WILSON\n1. Cambon, p. 292.\n\
		2. Temperley, p. 243.\n3. Webster, p. 15.\nCHAPTER 2: PARIS\n1. Ribot, p. 255.\n2. Callwell, p. 197.\n";

	fn link_to(doc: &Document, digits_at: usize) -> Option<usize> {
		let marker = doc
			.buffer
			.markers
			.iter()
			.find(|marker| marker.mtype == MarkerType::Link && marker.position == digits_at)?;
		doc.id_positions.get(marker.reference.trim_start_matches('#')).copied()
	}

	#[test]
	fn each_number_links_to_its_chapters_note_and_the_note_links_back() {
		let mut doc = doc(BOOK);
		assert_eq!(link_bare_notes(&mut doc), 5);
		let reference = BOOK.find("Paris was cold.1").unwrap() + "Paris was cold.".len();
		let note = BOOK.find("1. Ribot").unwrap();
		assert_eq!(link_to(&doc, reference), Some(note));
		assert_eq!(link_to(&doc, note), Some(reference));
	}

	#[test]
	fn the_word_notes_in_a_table_of_contents_is_not_the_notes() {
		let book = format!("Contents\nNotes\nBibliography\n{BOOK}");
		let mut doc = doc(&book);
		assert_eq!(link_bare_notes(&mut doc), 5);
	}

	#[test]
	fn years_decimals_and_numbers_after_a_space_are_not_references() {
		let line = Line {
			text: "In 1919 it rose 3.5 percent, by 12 points, to v3.0, and 1.2 million.",
			start: 0,
			heading: None,
		};
		assert!(
			references(&line).iter().all(|reference| !reference.clear),
			"only doubtful ones, for the line-up to settle"
		);
	}

	#[test]
	fn a_book_where_few_notes_find_a_number_is_left_alone() {
		let notes = (1..=20).map(|number| format!("{number}. Source.")).collect::<Vec<_>>().join("\n");
		let mut doc = doc(&format!("Chapter\nOne thing.1 Another thing.\nNotes\n{notes}"));
		assert_eq!(link_bare_notes(&mut doc), 0);
	}

	/// A stray number, a figure's, say, must not throw off the references after it, and a number after a number links
	/// only where the line-up expects it.
	#[test]
	fn stray_numbers_are_passed_over_and_doubtful_ones_fill_gaps() {
		let book = "Chapter One\nWilson sailed.1 See figure.1 The crowds were vast.2\nIt was April 22.3 He met them.4\n\
			Notes\nCHAPTER 1\n1. Cambon.\n2. Temperley.\n3. Webster.\n4. Ribot.\n";
		let mut doc = doc(book);
		assert_eq!(link_bare_notes(&mut doc), 4);
		let three = book.find("22.3").unwrap() + 3;
		assert_eq!(link_to(&doc, three), Some(book.find("3. Webster").unwrap()));
	}

	#[test]
	fn a_number_linked_only_to_a_whole_file_gets_a_link_to_its_note() {
		let mut doc = doc(BOOK);
		let at = BOOK.find("Europe.1").unwrap() + "Europe.".len();
		let mut marker = Marker::new(MarkerType::Link, at);
		marker.text = "1".to_string();
		marker.reference = "chapter3.docx".to_string();
		doc.buffer.add_marker(marker);
		assert_eq!(link_bare_notes(&mut doc), 5);
		assert_eq!(doc.buffer.markers.iter().filter(|marker| marker.position == at).count(), 1);
		assert_eq!(link_to(&doc, at), Some(BOOK.find("1. Cambon").unwrap()));
	}

	#[test]
	fn numbers_already_linked_are_left_as_they_are() {
		let mut doc = doc(BOOK);
		let at = BOOK.find("Europe.1").unwrap() + "Europe.".len();
		let mut marker = Marker::new(MarkerType::Link, at);
		marker.length = 1;
		marker.reference = "#existing".to_string();
		doc.buffer.add_marker(marker);
		link_bare_notes(&mut doc);
		assert_eq!(doc.buffer.markers.iter().filter(|marker| marker.position == at).count(), 1);
	}
}
