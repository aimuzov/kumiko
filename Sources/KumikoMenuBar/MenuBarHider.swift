import AppKit
import KumikoCore
import os

let log = Logger(subsystem: Kumiko.bundleIdentifier, category: "menubar")

/// Hides status items of the macOS menu bar, replacing Ice. Two items of its own do it:
/// a chevron that shows and hides, and a divider to its left. While the items are
/// hidden the divider is wider than any screen and pushes everything left of it past
/// the left edge. Which items hide is up to their order in the menu bar: cmd-drag an
/// item across the divider.
@MainActor
public final class MenuBarHider: NSObject {
	public private(set) var isHidden = true
	public var isInstalled: Bool { toggle != nil }

	private var config: Config.MenuBar
	private var toggle: NSStatusItem?
	private var divider: NSStatusItem?
	/// Keeps a status item as wide as an icon; off while the items are shown.
	private var dividerMinimum: NSLayoutConstraint?
	private var rehideTimer: Timer?
	private lazy var events = MenuBarEvents(
		onClick: { [weak self] point in self?.click(at: point) },
		onScroll: { [weak self] delta, point in self?.scroll(delta, at: point) }
	)

	private static let toggleName = "MenuBarToggle"
	private static let dividerName = "MenuBarDivider"
	/// Wider than any screen, so nothing left of the divider stays on one.
	private static let hidingLength: CGFloat = 10_000

	public init(config: Config.MenuBar) {
		self.config = config
	}

	public func start() {
		apply(config)
	}

	public func apply(_ config: Config.MenuBar) {
		self.config = config

		if config.enabled {
			install()
			events.start()
		} else {
			events.stop()
			uninstall()
		}
	}

	public func show() {
		guard isInstalled else { return }
		isHidden = false
		update()
	}

	public func hide() {
		guard isInstalled else { return }
		isHidden = true
		update()
	}

	public func toggleItems() {
		isHidden ? show() : hide()
	}

	/// `menubar show|hide|toggle`, from the CLI or a hotkey.
	public func handle(_ args: [String]) -> Response {
		guard isInstalled else { return .failure("menu bar hiding is off; turn it on with [menubar] enabled = true") }

		switch args.dropFirst().first {
		case "show": show()
		case "hide": hide()
		case "toggle": toggleItems()
		default: return .failure("usage: kumiko menubar show|hide|toggle")
		}
		return .success()
	}

	// MARK: - Items

	private func install() {
		guard toggle == nil else { return }
		Self.adoptIcePositions()

		let divider = NSStatusBar.system.statusItem(withLength: 0)
		divider.autosaveName = Self.dividerName
		if let button = divider.button {
			// Stretched over the empty menu bar, the divider would light up on a click.
			(button.cell as? NSButtonCell)?.highlightsBy = []
			button.target = self
			button.action = #selector(dividerClicked)
		}

		let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		toggle.autosaveName = Self.toggleName
		toggle.button?.target = self
		toggle.button?.action = #selector(toggleClicked)

		// AppKit's own constraint; without it on a new macOS the shown divider is a gap.
		if let button = divider.button {
			dividerMinimum = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal)
				.first { $0.secondItem === button.superview }
		}

		self.divider = divider
		self.toggle = toggle
		isHidden = true
		update()
	}

	private func uninstall() {
		rehideTimer?.invalidate()
		rehideTimer = nil
		[toggle, divider].compactMap(\.self).forEach(Self.remove)
		toggle = nil
		divider = nil
		dividerMinimum = nil
	}

	private func update() {
		guard let toggle, let divider else { return }

		// With the chevron dragged left of the divider, hiding would take the chevron away too
		// and leave nothing to bring the items back with.
		if isHidden, let dividerFrame = divider.button?.window?.frame, let toggleFrame = toggle.button?.window?.frame,
		   dividerFrame.minX > toggleFrame.minX
		{
			log.error("the divider is right of the chevron; cmd-drag it back to the left to hide items")
			isHidden = false
		}

		// The length only takes while the constraint is on: it goes on first and off last.
		if isHidden { dividerMinimum?.isActive = true }
		divider.length = isHidden ? Self.hidingLength : 0
		if !isHidden, let minimum = dividerMinimum, let window = divider.button?.window {
			minimum.isActive = false
			// Without the constraint the window keeps its old width until told otherwise.
			window.setContentSize(CGSize(width: 1, height: window.frame.height))
		}
		toggle.button?.image = NSImage(
			systemSymbolName: isHidden ? "chevron.left" : "chevron.right",
			accessibilityDescription: isHidden ? "Show menu bar items" : "Hide menu bar items"
		)
		scheduleRehide()
	}

	private func scheduleRehide() {
		rehideTimer?.invalidate()
		rehideTimer = nil
		guard !isHidden, config.rehide > 0 else { return }

		rehideTimer = Timer.scheduledTimer(withTimeInterval: config.rehide, repeats: false) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				// The pointer still on the menu bar means an item is in use; check again later.
				if MenuBarGeometry.screen(at: MenuBarGeometry.mouseLocation) != nil {
					self.scheduleRehide()
				} else {
					self.hide()
				}
			}
		}
	}

	@objc private func toggleClicked() {
		toggleItems()
	}

	/// Only reachable while the items are hidden: then the divider covers the empty part of
	/// the menu bar.
	@objc private func dividerClicked() {
		if config.showOnClick { show() }
	}

	// MARK: - Events

	private func click(at point: CGPoint) {
		// Hidden items are shown by the divider, which takes the click itself.
		guard !isHidden, config.showOnClick, MenuBarGeometry.isEmptySpace(point) else { return }
		hide()
	}

	private func scroll(_ delta: CGFloat, at point: CGPoint) {
		guard config.showOnScroll, MenuBarGeometry.screen(at: point) != nil else { return }

		if delta > 5 {
			show()
		} else if delta < -5 {
			hide()
		}
	}

	// MARK: - Positions

	/// AppKit keeps where an item was dragged under this key, in the app's own defaults.
	private static func positionKey(_ name: String) -> String {
		"NSStatusItem Preferred Position \(name)"
	}

	/// The first time, the chevron and the divider take the places of Ice's, so the icons
	/// hidden there stay hidden here. Without Ice they go to the right end, next to the
	/// system items.
	private static func adoptIcePositions() {
		let pairs = [(toggleName, "SItem", 0.0), (dividerName, "HItem", 1.0)]

		for (name, iceName, fallback) in pairs where UserDefaults.standard.object(forKey: positionKey(name)) == nil {
			let ice = CFPreferencesCopyAppValue(positionKey(iceName) as CFString, "com.jordanbaird.Ice" as CFString)
			UserDefaults.standard.set((ice as? Double) ?? fallback, forKey: positionKey(name))
		}
	}

	/// Removing an item makes AppKit forget its place; the place is put back so turning the
	/// module off and on again does not move the divider.
	private static func remove(_ item: NSStatusItem) {
		let key = positionKey(item.autosaveName)
		let position = UserDefaults.standard.object(forKey: key)
		NSStatusBar.system.removeStatusItem(item)
		UserDefaults.standard.set(position, forKey: key)
	}
}
