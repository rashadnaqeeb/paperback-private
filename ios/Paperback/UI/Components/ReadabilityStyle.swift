import SwiftUI

/// Document text in the system's body style, so the reader's own text size applies, in pure
/// black on white or white on black when iOS's Increase Contrast is on.
struct ReadabilityStyle: ViewModifier {
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.colorSchemeContrast) private var systemContrast

	private var textColor: Color {
		guard systemContrast == .increased else { return .primary }
		return colorScheme == .dark ? .white : .black
	}

	func body(content: Content) -> some View {
		content
			.font(.body)
			.padding(.vertical, 2)
			.frame(maxWidth: .infinity, alignment: .leading)
			.foregroundStyle(textColor)
	}
}

/// The page behind the text, which has to move with the text colour or increased contrast
/// would put pure white on the system's off-white background.
struct ReadingBackground: ViewModifier {
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.colorSchemeContrast) private var systemContrast

	func body(content: Content) -> some View {
		if systemContrast == .increased {
			content.background(colorScheme == .dark ? Color.black : Color.white)
		} else {
			content
		}
	}
}

extension View {
	func readabilityStyle() -> some View {
		modifier(ReadabilityStyle())
	}

	func readingBackground() -> some View {
		modifier(ReadingBackground())
	}
}
