import CoreGraphics

/// A window as kumiko sees it: plain data, safe to hand to any module or print as JSON.
public struct WindowInfo: Codable, Equatable, Sendable {
	/// The WindowServer id, stable for the life of the window and the same one other tools show.
	public var id: UInt32
	public var pid: Int32
	public var app: String
	public var bundleID: String?
	public var title: String
	/// `AXStandardWindow` for ordinary windows; dialogs, sheets and panels say something else.
	public var subrole: String?
	public var frame: CGRect
	public var isMinimized: Bool
	/// The app is hidden (cmd-h), so the window is not on screen though it still exists.
	public var isHidden: Bool
	public var isManaged: Bool

	public init(
		id: UInt32, pid: Int32, app: String, bundleID: String?, title: String, subrole: String?,
		frame: CGRect, isMinimized: Bool, isHidden: Bool, isManaged: Bool
	) {
		self.id = id
		self.pid = pid
		self.app = app
		self.bundleID = bundleID
		self.title = title
		self.subrole = subrole
		self.frame = frame
		self.isMinimized = isMinimized
		self.isHidden = isHidden
		self.isManaged = isManaged
	}
}
