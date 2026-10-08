import Foundation

/// The one book being read. Only one is ever open: opening another closes this one.
struct OpenBook: Equatable {
	var title: String
	var url: URL
	var lineScrollIndex: Int = 0
	var currentPosition: Int64 = 0
	var session: DocumentSession?

	static func == (lhs: OpenBook, rhs: OpenBook) -> Bool {
		lhs.url == rhs.url
	}
}
