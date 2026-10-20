//! Removes spaces an EPUB's typesetting puts before punctuation, which a screen reader reads as a pause or a stray
//! symbol. It works on a section's markup before conversion, so markers and ids are placed in the tidied text.
//!
//! Many books' markup is pretty-printed with each italic or styled word on a line of its own. A line break between
//! words is a space, so "the <em>Xenophobe</em>?" in print reads "the Xenophobe ?". The line break only says where the
//! tool wrapped the markup, so it goes when punctuation that never follows a space in English meets the styled word,
//! or an opening quote or bracket meets it from before. A space typed into the text is left alone.
//!
//! An ellipsis set as spaced periods (". . .") reads as three dots; it becomes one ellipsis character, and the space
//! between it and a question mark, exclamation mark, or closing quote goes as well.
//!
//! French puts a space before "? ! ; :" and inside guillemets, so in a French section those spaces stay.

use std::sync::LazyLock;

use regex::{Captures, Regex};

/// Inline elements, whose ends a pretty-printer can leave on lines of their own.
const INLINE: &str = "a|abbr|b|bdi|bdo|big|cite|code|del|dfn|em|font|i|ins|kbd|mark|q|s|samp|small|span|strike|strong|sub|sup|time|tt|u|var";
/// Punctuation that attaches to the word before it. An ellipsis can stand apart from the word, so it is not here.
const CLOSING: &str = r"[.,;:?!)\]\x{201D}\x{2019}\x{BB}]";
/// Punctuation that attaches to the word after it.
const OPENING: &str = r"[\x{201C}\x{2018}(\[\x{AB}]";
/// What French sets apart from the word with a space.
const FRENCH_SPACED: &[char] = &['?', '!', ';', ':', '\u{BB}', '\u{AB}'];
/// A space, or a no-break space as character or entity, between the periods of a spaced ellipsis.
const DOT_GAP: &str = r"(?:[ \x{A0}\x{202F}]|&nbsp;|&#160;|&#8239;|&#x[aA]0;|&#x202[fF];)";

/// Closing tags, maybe nested, then the punctuation after them.
static AFTER_INLINE: LazyLock<Regex> = LazyLock::new(|| {
	Regex::new(&format!(r"((?:</(?:{INLINE})>[ \t\r\n]*)+)({CLOSING})")).expect("valid after-inline pattern")
});
/// Punctuation that is all of a styled element, as in "<i>.</i>", with the opening tags before it. A styled phrase
/// that merely starts with a mark ("<i>’Tis</i>") keeps the space before it.
static INSIDE_INLINE: LazyLock<Regex> = LazyLock::new(|| {
	Regex::new(&format!(r"([ \t\r\n]+(?:<(?:{INLINE})\b[^>]*>[ \t\r\n]*)+)([.,;:?!]+</)"))
		.expect("valid inside-inline pattern")
});
/// Opening punctuation, then the opening tags after it.
static BEFORE_INLINE: LazyLock<Regex> = LazyLock::new(|| {
	Regex::new(&format!(r"({OPENING})((?:[ \t\r\n]*<(?:{INLINE})\b[^>]*>)+)")).expect("valid before-inline pattern")
});
static SPACED_DOTS: LazyLock<Regex> = LazyLock::new(|| {
	Regex::new(&format!(r"\.(?:{DOT_GAP}\.)+(?:({DOT_GAP}+)([?!\x{{201D}})]))?")).expect("valid spaced-dots pattern")
});
/// Preformatted text keeps its line breaks, which is where code lives.
static PRE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<pre[\s>].*?</pre>").expect("valid pre pattern"));
static HTML_LANG: LazyLock<Regex> =
	LazyLock::new(|| Regex::new(r#"<html\b[^>]*?\blang\s*=\s*["']([^"']*)"#).expect("valid lang pattern"));

/// The section's markup with typesetting spaces removed from around its punctuation.
pub fn tidy_markup(content: &str) -> String {
	let french = HTML_LANG.captures(content).is_some_and(|caps| caps[1].trim().to_ascii_lowercase().starts_with("fr"));
	let mut out = String::with_capacity(content.len());
	let mut last = 0;
	for pre in PRE.find_iter(content) {
		out.push_str(&tidy_prose(&content[last..pre.start()], french));
		out.push_str(pre.as_str());
		last = pre.end();
	}
	out.push_str(&tidy_prose(&content[last..], french));
	out
}

fn tidy_prose(markup: &str, french: bool) -> String {
	// Only a line break says the markup was wrapped, and French keeps its space before some marks.
	let wrapped = |tags: &str, mark: &str| tags.contains('\n') && !(french && mark.starts_with(FRENCH_SPACED));
	let markup = AFTER_INLINE.replace_all(markup, |caps: &Captures| {
		if wrapped(&caps[1], &caps[2]) { format!("{}{}", unwrapped(&caps[1]), &caps[2]) } else { caps[0].to_string() }
	});
	let markup = INSIDE_INLINE.replace_all(&markup, |caps: &Captures| {
		if wrapped(&caps[1], &caps[2]) { format!("{}{}", unwrapped(&caps[1]), &caps[2]) } else { caps[0].to_string() }
	});
	let markup = BEFORE_INLINE.replace_all(&markup, |caps: &Captures| {
		if wrapped(&caps[2], &caps[1]) { format!("{}{}", &caps[1], unwrapped(&caps[2])) } else { caps[0].to_string() }
	});
	SPACED_DOTS
		.replace_all(&markup, |caps: &Captures| {
			let whole = caps.get(0).expect("whole match");
			let attached = markup[..whole.start()].chars().next_back().is_some_and(|c| !c.is_whitespace() && c != ';');
			// Two periods are a typo, and five or more are leaders or a row of dots, so neither is an ellipsis.
			let ellipsis = match whole.as_str().matches('.').count() {
				3 => "\u{2026}",
				// A sentence's own period before the ellipsis when it closes a word, the period after it otherwise.
				4 if attached => ". \u{2026}",
				4 => "\u{2026}.",
				_ => return whole.as_str().to_string(),
			};
			match (caps.get(1), caps.get(2)) {
				(Some(gap), Some(mark)) if french && mark.as_str().starts_with(FRENCH_SPACED) => {
					format!("{ellipsis}{}{}", gap.as_str(), mark.as_str())
				}
				(_, Some(mark)) => format!("{ellipsis}{}", mark.as_str()),
				_ => ellipsis.to_string(),
			}
		})
		.into_owned()
}

/// Tags with the whitespace between them removed. Whitespace inside a tag is a single space and stays.
fn unwrapped(tags: &str) -> String {
	let mut out = String::with_capacity(tags.len());
	let mut in_tag = false;
	for c in tags.chars() {
		match c {
			'<' => in_tag = true,
			'>' => in_tag = false,
			_ if !in_tag && c.is_ascii_whitespace() => continue,
			_ => {}
		}
		out.push(c);
	}
	out
}

#[cfg(test)]
mod tests {
	use super::*;

	fn english(body: &str) -> String {
		tidy_markup(&format!("<html xml:lang=\"en-US\"><body>{body}</body></html>"))
	}

	fn french(body: &str) -> String {
		tidy_markup(&format!("<html lang=\"fr\"><body>{body}</body></html>"))
	}

	#[test]
	fn punctuation_wrapped_onto_the_line_after_a_styled_word_closes_up() {
		assert!(english("<p>first night on the\n  <em>Xenophobe</em>\n  ?”</p>").contains("<em>Xenophobe</em>?”"));
		assert!(
			english("<p>Watching <span class=\"sc\">You</span>\r\n  , the caption</p>").contains("You</span>, the")
		);
	}

	#[test]
	fn nested_closing_tags_close_up_together() {
		assert!(english("<p><b><i>Costa Rica</i>\n  </b>\n  , the last</p>").contains("Rica</i></b>, the"));
	}

	#[test]
	fn an_opening_quote_or_bracket_closes_up_to_the_styled_word_after_it() {
		assert!(english("<p>“\n  <em>Shadow</em>, trading”</p>").contains("“<em>Shadow</em>"));
		assert!(english("<p>(\n  <i>artsem</i>, it was called)</p>").contains("(<i>artsem</i>"));
	}

	#[test]
	fn punctuation_styled_on_its_own_closes_up_to_the_word_before() {
		assert!(
			english("<p>such stories\n  <i class=\"c\">.</i>\n  Readers</p>").contains("stories<i class=\"c\">.</i>")
		);
	}

	#[test]
	fn a_styled_phrase_starting_with_a_mark_keeps_its_space() {
		assert!(english("<p>Devi:\n  <i>…Sure.</i></p>").contains("Devi:\n  <i>…Sure."));
		assert!(english("<p>he said\n  <i>’Tis so.</i></p>").contains("said\n  <i>’Tis"));
	}

	#[test]
	fn a_space_typed_into_the_text_stays() {
		assert!(english("<p>Where is <em>Yacef</em> ? Where</p>").contains("</em> ? Where"));
		assert!(english("<p>The Arabs : a history</p>").contains("Arabs : a"));
	}

	#[test]
	fn a_space_on_the_word_side_of_a_tag_or_before_other_marks_stays() {
		assert!(english("<p>word\n  <em>next</em>\n  and on</p>").contains("<em>next</em>\n  and"));
		assert!(english("<p><em>word</em>\n  — and on</p>").contains("</em>\n  — and"));
	}

	#[test]
	fn preformatted_text_is_left_alone() {
		let code = "<pre><span>f(x</span>\n)</pre>";
		assert!(english(code).contains(code));
	}

	#[test]
	fn a_spaced_ellipsis_becomes_one_character() {
		assert!(english("<p>an entire planet . . . ?</p>").contains("planet …?</p>"));
		assert!(english("<p>drawing . . . ” He laughed</p>").contains("drawing …” He"));
		assert!(english("<p>chant of “B-B! . . . B-B!”</p>").contains("B-B! … B-B!"));
		assert!(english("<p>not quite&#160;.&#160;.&#160;. yet</p>").contains("quite&#160;… yet"));
	}

	#[test]
	fn a_four_dot_ellipsis_keeps_its_sentence_period() {
		assert!(english("<p>struck him.\u{A0}.\u{A0}.\u{A0}.</p>").contains("him. …</p>"));
		assert!(english("<p>and they went . . . . That</p>").contains("went …. That"));
	}

	#[test]
	fn two_dots_and_rows_of_dots_are_not_an_ellipsis() {
		assert!(english("<p>neighbors . . Al</p>").contains("neighbors . . Al"));
		assert!(english("<p>Preface . . . . . . vii</p>").contains("Preface . . . . . . vii"));
	}

	#[test]
	fn french_keeps_its_space_before_high_marks_and_inside_guillemets() {
		assert!(french("<p>le\n  <em>Xenophobe</em>\n  ?</p>").contains("</em>\n  ?"));
		assert!(french("<p>«\n  <em>Ombre</em>\n  »</p>").contains("«\n  <em>Ombre</em>\n  »"));
		assert!(french("<p>une <em>planète</em>\n  , puis</p>").contains("</em>, puis"));
		assert!(french("<p>une planète . . . ?</p>").contains("planète … ?"));
	}

	#[test]
	fn the_book_reads_without_stray_spaces() {
		let Some(path) = std::env::var_os("HOME").map(|home| {
			std::path::Path::new(&home)
				.join("Library/Mobile Documents/com~apple~CloudDocs/books/Use_of_Weapons_rashad_naqeeb.epub")
		}) else {
			return;
		};
		if !path.is_file() {
			return;
		}
		let context = crate::document::ParserContext::new(path.to_string_lossy().into_owned());
		let text = super::super::parse_document(&context).expect("parse fixture").buffer.content;
		assert!(text.contains("an entire fucking planet …?"));
		assert!(text.contains("first night on the Xenophobe?”"));
		assert!(text.contains("any silly GCU can do that!”"));
		assert!(!text.contains(". . ."));
	}
}
