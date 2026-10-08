import SwiftUI

/// SwiftUI's handle on the UIKit reading surface.
struct ReadingScreen: UIViewControllerRepresentable {
	let viewModel: AppViewModel
	let session: DocumentSession

	func makeUIViewController(context: Context) -> ReadingViewController {
		let text = BookText(session: session)
		let controller = ReadingViewController(text: text, startIndex: text.element(forPosition: viewModel.reading.position))
		let reading = viewModel.reading
		controller.onPositionChange = { reading.readerMoved(to: $0) }
		controller.onExit = { [weak viewModel] in viewModel?.closeBook() }
		controller.menuItems = { [weak viewModel] in
			guard let viewModel else { return [] }
			let navigation = viewModel.navigation
			return [
				// TRANSLATORS: In-book menu item that closes the book and returns to the list of books
				ReadingMenuItem(title: t("Exit Book")) { viewModel.closeBook() },
				// TRANSLATORS: Menu item to open the document's table of contents
				ReadingMenuItem(title: t("Table of Contents")) { navigation.showToc = true },
				// TRANSLATORS: Menu item to open the list of headings and links found in the document
				ReadingMenuItem(title: t("Elements")) { navigation.showElements = true },
				// TRANSLATORS: Menu item to open find-in-document search
				ReadingMenuItem(title: t("Find")) { navigation.showFind = true },
				// TRANSLATORS: Menu item to jump to a specific page, line, or percentage in the document
				ReadingMenuItem(title: t("Go To...")) { navigation.showGoTo = true },
				// TRANSLATORS: Menu item to show document metadata (title, author, format, etc.)
				ReadingMenuItem(title: t("Document Info")) { navigation.showDocumentInfo = true },
				// TRANSLATORS: Menu item to open the app's settings
				ReadingMenuItem(title: t("Settings")) { navigation.showSettings = true },
			]
		}
		reading.onJump = { [weak controller] position in
			controller?.go(to: text.element(forPosition: position))
		}
		return controller
	}

	func updateUIViewController(_ controller: ReadingViewController, context: Context) {
		controller.menuTitle = viewModel.book?.title ?? ""
	}
}
