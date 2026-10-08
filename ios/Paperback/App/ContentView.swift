import SwiftUI
import UIKit

struct ContentView: View {
	// Handed in by the scene that owns it, rather than created here: the scene's window needs
	// the same instance to route the magic tap.
	let viewModel: AppViewModel

	var body: some View {
		// The environment object goes on the stack, not on BooksView: content pushed via
		// navigationDestination is hosted by the stack, so it only inherits what the stack
		// itself carries.
		NavigationStack {
			BooksView()
		}
		.environment(viewModel)
	}
}
