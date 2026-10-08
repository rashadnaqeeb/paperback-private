import SwiftUI

/// SwiftUI's handle on the UIKit reading surface.
struct ReadingScreen: UIViewControllerRepresentable {
	let viewModel: AppViewModel
	let session: DocumentSession

	func makeUIViewController(context: Context) -> ReadingViewController {
		let model = BookModel(session: session)
		let reading = viewModel.reading
		let controller = ReadingViewController(model: model, startUnit: model.unit(forPosition: reading.position))
		controller.onPositionChange = { reading.readerMoved(to: $0) }
		let navigation = viewModel.navigation
		controller.onMenu = { navigation.showBookMenu = true }
		reading.onJump = { [weak controller] position in
			controller?.jump(toPosition: position)
		}
		return controller
	}

	func updateUIViewController(_ controller: ReadingViewController, context: Context) {}
}
