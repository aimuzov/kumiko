import AppKit
import KumikoCore
import os

private let log = Logger(subsystem: Kumiko.bundleIdentifier, category: "menubar")

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
	/// Set while items are cmd-dragged, to whether they were hidden before the drag.
	private var hiddenBeforeDrag: Bool?
	private var mouseMonitors: [Any] = []

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
		} else {
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

	/// A status item of another app: the app's name, or for the system's own items (Wi-Fi, the
	/// clock) what the item says it is.
	public struct Item: Equatable, Sendable {
		public let name: String
		public let pid: pid_t
	}

	/// The items in the menu bar either side of the divider, each side from left to right; nil
	/// while the module is off. Since macOS 26 every item's window belongs to Control Center, so
	/// the window list cannot tell whose an item is; each app's extras menu bar in Accessibility
	/// can, with where its items are.
	public func items() -> (hidden: [Item], shown: [Item])? {
		guard let dividerMid = divider?.button?.window?.frame.midX else { return nil }

		let system: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver"]
		var found: [(item: Item, midX: CGFloat)] = []

		for app in NSWorkspace.shared.runningApplications where app.processIdentifier != getpid() {
			let element = AXUIElementCreateApplication(app.processIdentifier)
			// An app that hangs must not hang the settings window with it.
			AXUIElementSetMessagingTimeout(element, 0.1)

			var bar: CFTypeRef?
			var children: CFTypeRef?
			guard
				AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &bar) == .success,
				let bar, CFGetTypeID(bar) == AXUIElementGetTypeID(),
				AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
				let items = children as? [AXUIElement]
			else { continue }

			let isSystem = system.contains(app.bundleIdentifier ?? "")

			for item in items {
				guard let frame = Self.frame(of: item) else { continue }

				let name: String
				if isSystem {
					// Control Center also hosts other apps' items, unnamed; those apps list them
					// themselves, so only the system's own, named items count here.
					guard let label = Self.label(of: item) else { continue }
					// "Wi-Fi, connected, 3 bars" is the Wi-Fi item.
					name = label.components(separatedBy: ",")[0]
				} else {
					name = app.localizedName ?? "pid \(app.processIdentifier)"
				}
				found.append((Item(name: name, pid: app.processIdentifier), frame.midX))
			}
		}

		let sorted = found.sorted { $0.midX < $1.midX }
		return (
			sorted.filter { $0.midX < dividerMid }.map(\.item),
			sorted.filter { $0.midX > dividerMid }.map(\.item)
		)
	}

	private static func frame(of element: AXUIElement) -> CGRect? {
		var position: CFTypeRef?
		var size: CFTypeRef?
		var point = CGPoint.zero
		var extent = CGSize.zero
		guard
			AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
			AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
			AXValueGetValue(position as! AXValue, .cgPoint, &point),
			AXValueGetValue(size as! AXValue, .cgSize, &extent)
		else { return nil }
		return CGRect(origin: point, size: extent)
	}

	private static func label(of element: AXUIElement) -> String? {
		for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
			var value: CFTypeRef?
			if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
			   let text = value as? String, !text.isEmpty {
				return text
			}
		}
		return nil
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

		// A drag ending over kumiko's own items reaches only the local monitor.
		let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
		mouseMonitors = [
			NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self] event in
				MainActor.assumeIsolated { self?.mouse(event) }
			},
			NSEvent.addLocalMonitorForEvents(matching: mouse) { [weak self] event in
				MainActor.assumeIsolated { self?.mouse(event) }
				return event
			},
		].compactMap(\.self)
	}

	private func uninstall() {
		rehideTimer?.invalidate()
		rehideTimer = nil
		mouseMonitors.forEach(NSEvent.removeMonitor)
		mouseMonitors = []
		hiddenBeforeDrag = nil
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

		let isDragging = hiddenBeforeDrag != nil
		divider.button?.image = isDragging
			? NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Items left of here hide")
			: nil

		// The length only takes while the constraint is on: it goes on first and off last.
		if isHidden || isDragging { dividerMinimum?.isActive = true }
		divider.length = isHidden ? Self.hidingLength : isDragging ? NSStatusItem.variableLength : 0
		if !isHidden, !isDragging, let minimum = dividerMinimum, let window = divider.button?.window {
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
		guard !isHidden, hiddenBeforeDrag == nil, config.rehide > 0 else { return }

		rehideTimer = Timer.scheduledTimer(withTimeInterval: config.rehide, repeats: false) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				// The pointer still on the menu bar means an item is in use; check again later.
				if Self.isPointerOnMenuBar {
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

	/// A cmd-press on the menu bar starts dragging an item. Until it is dropped every item is
	/// shown and the divider is drawn, so there is something to drag across.
	private func mouse(_ event: NSEvent) {
		switch event.type {
		case .leftMouseDown where event.modifierFlags.contains(.command) && Self.isPointerOnMenuBar:
			guard hiddenBeforeDrag == nil else { return }
			hiddenBeforeDrag = isHidden
			isHidden = false
			update()
		case .leftMouseUp:
			guard let wasHidden = hiddenBeforeDrag else { return }
			hiddenBeforeDrag = nil
			isHidden = wasHidden
			update()
		default:
			break
		}
	}

	private static var isPointerOnMenuBar: Bool {
		let point = NSEvent.mouseLocation
		return NSScreen.screens.contains { $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY }
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
