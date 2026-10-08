import SwiftUI

/// Where the reader is in the book, and search within it. The only place the app reports position, apart from the
/// three-finger tap.
struct BookInfoView: View {
	@Environment(AppViewModel.self) private var viewModel
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var results: [FindAllLineFfi]?
	/// The book's printed page numbers, which the search's page counts index.
	@State private var pageLabels: [String] = []

	var body: some View {
		List {
			Section {
				// TRANSLATORS: Label of the book's title in the in-book menu
				LabeledContent(t("Title"), value: viewModel.book?.title ?? "")
				if let author = viewModel.activeSession?.author(), !author.isEmpty {
					// TRANSLATORS: Label of the book's author in the in-book menu
					LabeledContent(t("Author"), value: author)
				}
				if let chapter = viewModel.chapterTitle(at: viewModel.reading.position) {
					// TRANSLATORS: Label of the chapter being read in the in-book menu
					LabeledContent(t("Chapter"), value: chapter)
				}
				// TRANSLATORS: Label of how far through the book the reader is, in the in-book menu
				LabeledContent(t("Read"), value: "\(viewModel.percentRead)%")
			}
			Section {
				// TRANSLATORS: Placeholder of the field searching the book
				TextField(t("Search the book"), text: $query)
					.submitLabel(.search)
					.onSubmit(search)
				if let results {
					if results.isEmpty {
						// TRANSLATORS: Shown when a search of the book finds nothing
						Text(t("No matches."))
					}
					ForEach(results, id: \.position) { result in
						Button {
							viewModel.reading.goToPosition(result.position, announce: true)
							dismiss()
						} label: {
							VStack(alignment: .leading) {
								Text(result.text).lineLimit(3)
								if pageLabels.indices.contains(Int(result.page) - 1) {
									Text(BookModel.pageName(pageLabels[Int(result.page) - 1]))
										.font(.caption)
										.foregroundStyle(.secondary)
								}
							}
						}
					}
				}
			} header: {
				// TRANSLATORS: Header of the search section of the in-book menu
				Text(t("Search"))
			}
		}
		// TRANSLATORS: Title of the in-book menu's information and search tab
		.navigationTitle(t("Info and Search"))
		.navigationBarTitleDisplayMode(.inline)
	}

	private func search() {
		let trimmed = query.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty, let session = viewModel.activeSession else { return }
		let found = session.findAllFfi(query: trimmed, options: SearchOptionsFfi(matchCase: false, wholeWord: false, regex: false, forward: true))
		// The engine counts pages from the first; the reader knows them by their printed numbers.
		pageLabels = session.getStructureMarkersFfi().filter { $0.mtype == .pageBreak }.map(\.text)
		results = found
		// TRANSLATORS: Spoken after searching the book; {} is the number of lines that matched. Which of the three forms is used depends on the language's plural rule, and the "many" form's trailing character isn't a typo.
		let summary = nt(t("{} match"), t("{} matches"), t("{} matches⁣"), found.count).replacingOccurrences(of: "{}", with: "\(found.count)")
		UIAccessibility.post(notification: .announcement, argument: summary)
	}
}
