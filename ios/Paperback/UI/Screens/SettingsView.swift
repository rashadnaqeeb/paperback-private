import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
	@Environment(AppViewModel.self) private var viewModel
	@State private var choosingFolder = false

	var body: some View {
		@Bindable var viewModel = viewModel
		Form {
			Section {
				Button { choosingFolder = true } label: {
					// TRANSLATORS: Settings row naming the books folder; choosing it opens the folder picker to pick a different one
					LabeledContent {
						Text(viewModel.booksFolder.folderURL?.lastPathComponent ?? "").foregroundStyle(.secondary)
					} label: {
						Text(t("Books Folder"))
					}
				}
			} footer: {
				// TRANSLATORS: Footer under the Books Folder row in Settings, explaining what choosing it does
				Text(t("Choose a different folder to list on the Books screen."))
			}
			Section {
				// TRANSLATORS: Toggle controlling whether an upward swipe advances (vs. reverses) navigation
				Toggle(t("Swipe up moves forward"), isOn: $viewModel.swipeUpMovesForward)
				// TRANSLATORS: Toggle that removes the reading bar's previous/next buttons from the screen reader's swipe order, since the play button's swipe up/down does the same thing
				Toggle(t("Hide previous and next buttons"), isOn: $viewModel.hidePrevNextButtons)
			} header: {
				// TRANSLATORS: Section header in Settings grouping the controls of the player for books with recorded narration
				Text(t("Audiobooks"))
			} footer: {
				// TRANSLATORS: Footer explaining the "Swipe up moves forward" toggle above it
				Text(t("With VoiceOver, swipe up on the play button to move forward, or down to move back."))
			}
			Section {
				// iOS keeps a language for each app on its own page in the Settings app, which is where the system lets one be chosen: an app that changes it itself only sees the change after a relaunch.
				Button {
					if let url = URL(string: UIApplication.openSettingsURLString) {
						UIApplication.shared.open(url)
					}
				} label: {
					// TRANSLATORS: Settings row showing the language Paperback is shown in; choosing it opens Paperback's page in the system Settings app, where the language can be changed
					LabeledContent {
						Text(currentLanguageName).foregroundStyle(.secondary)
					} label: {
						Text(t("Language"))
					}
				}
			} footer: {
				// TRANSLATORS: Footer under the Language row in Settings, explaining where it leads
				Text(t("Opens Paperback in the Settings app, where its language can be changed."))
			}
		}
		// TRANSLATORS: Navigation bar title of the Settings screen
		.navigationTitle(t("Settings"))
		.navigationBarTitleDisplayMode(.inline)
		.fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
			guard case .success(let url) = result else { return }
			viewModel.booksFolder.choose(url)
		}
	}

	/// The language the app is shown in, named in that language, as the iOS language list names them.
	private var currentLanguageName: String {
		let code = Bundle.main.preferredLocalizations.first ?? "en"
		let locale = Locale(identifier: code)
		return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
	}
}
