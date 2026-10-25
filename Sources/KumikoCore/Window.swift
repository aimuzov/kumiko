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
	/// What the app calls the window (`AXIdentifier`), there when it has no title too.
	public var identifier: String?
	/// False for a window of one size only, as settings windows mostly are: no layout can fit it.
	public var isResizable: Bool
	public var frame: CGRect
	public var isMinimized: Bool
	/// The app is hidden (cmd-h), so the window is not on screen though it still exists.
	public var isHidden: Bool
	/// In macOS native full screen: the window has a native Space of its own and is left alone.
	public var isFullscreen: Bool
	public var isManaged: Bool

	public init(
		id: UInt32, pid: Int32, app: String, bundleID: String?, title: String, subrole: String?,
		frame: CGRect, isMinimized: Bool, isHidden: Bool, isFullscreen: Bool, isManaged: Bool, identifier: String? = nil,
		isResizable: Bool = true
	) {
		self.identifier = identifier
		self.isResizable = isResizable
		self.id = id
		self.pid = pid
		self.app = app
		self.bundleID = bundleID
		self.title = title
		self.subrole = subrole
		self.frame = frame
		self.isMinimized = isMinimized
		self.isHidden = isHidden
		self.isFullscreen = isFullscreen
		self.isManaged = isManaged
	}
}
