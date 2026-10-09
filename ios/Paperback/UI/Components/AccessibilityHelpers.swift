import SwiftUI

private struct SheetFocusModifier: ViewModifier {
	let title: String
	let enabled: Bool
	@AccessibilityFocusState private var focused: Bool

	func body(content: Content) -> some View {
		content
			.overlay(alignment: .top) {
				Text(title)
					.frame(height: 0)
					.opacity(0)
					.accessibilityFocused($focused)
			}
			.onAppear {
				guard enabled else { return }
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
					focused = true
				}
			}
	}
}

extension View {
	func sheetAccessibilityFocus(title: String, enabled: Bool = true) -> some View {
		modifier(SheetFocusModifier(title: title, enabled: enabled))
	}
}
