import AppKit
import KumikoCore
import KumikoMenuBar
import SwiftUI

extension SettingsModel {
	/// Right to left, as the list shows them: the item next to the clock first, then the one
	/// next to the divider first.
	var menuBarList: (shown: [MenuBarHider.Item], hidden: [MenuBarHider.Item])? {
		menuBarItems.map { (Array($0.shown.reversed()), Array($0.hidden.reversed())) }
	}

	func readMenuBarItems() {
		let items = menuBar()?.items()
		if items?.hidden != menuBarItems?.hidden || items?.shown != menuBarItems?.shown {
			menuBarItems = items
		}

		let windows = ((items?.shown ?? []) + (items?.hidden ?? [])).compactMap(\.windowID)
		let missing = windows.filter { menuBarSnapshots[$0] == nil }
		guard !missing.isEmpty else { return }
		Task { [weak self] in
			let images = await MenuBarSnapshots.images(of: missing)
			guard let self, !images.isEmpty else { return }
			self.menuBarSnapshots.merge(images) { _, new in new }
		}
	}

	/// Items moved in the menu bar show up here within a second.
	func watchMenuBar(_ on: Bool) {
		menuBarWatch?.invalidate()
		menuBarWatch = nil
		guard on else { return }
		menuBarSnapshots = [:]
		readMenuBarItems()
		let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.readMenuBarItems() }
		}
		RunLoop.main.add(timer, forMode: .common)
		menuBarWatch = timer
	}
}

/// The items either side of kumiko's divider, as they stand in the menu bar. Moving one stays
/// the menu bar's own cmd-drag: an app can only move another's item by driving the pointer.
struct MenuBarPage: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		Group {
			if let list = model.menuBarList {
				ItemsCard(
					title: "Shown", items: list.shown, snapshots: model.menuBarSnapshots,
					empty: "Cmd-drag items right of the divider to keep them shown."
				)
				ItemsCard(
					title: "Hidden", items: list.hidden, snapshots: model.menuBarSnapshots,
					empty: "Cmd-drag items left of the divider to hide them."
				)

				if !MenuBarSnapshots.isAllowed {
					Card {
						Row(
							title: "Show items as they look",
							detail: "With Screen Recording, the list shows each item the way the menu bar draws it.",
							last: true
						) {
							Button("Allow…") { MenuBarSnapshots.requestAccess() }
						}
					}
				}
			} else {
				Card {
					Row(title: "Menu Bar is off", detail: "Turn it on with the switch above to hide items.", last: true) {
						EmptyView()
					}
				}
			}

			Card(title: "Hiding") {
				StepperRow(
					title: "Hide again after",
					detail: "Cmd-drag an item across the divider in the menu bar to move it between the lists.",
					value: model.binding(\.menuBar.rehide, "menubar", "rehide"),
					range: 0...120,
					step: 5,
					unit: "s",
					zero: "Never",
					last: true,
					reset: model.reset(\.menuBar.rehide, "menubar", "rehide")
				)
			}
		}
		.onAppear { model.watchMenuBar(true) }
		.onDisappear { model.watchMenuBar(false) }
	}
}

/// Menu bar items as rows, each as the menu bar draws it.
private struct ItemsCard: View {
	let title: String
	let items: [MenuBarHider.Item]
	let snapshots: [CGWindowID: NSImage]
	let empty: String

	var body: some View {
		Card(title: title) {
			if items.isEmpty {
				Row(title: empty, last: true) { EmptyView() }
			}
			ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
				VStack(spacing: 0) {
					HStack(spacing: 10) {
						MenuBarItemPicture(item: item, snapshot: item.windowID.flatMap { snapshots[$0] })
						Text(item.name)
							.lineLimit(1)
							.truncationMode(.tail)
						Spacer()
					}
					.frame(height: 36)

					if index < items.count - 1 {
						Divider()
					}
				}
			}
		}
	}
}

/// The item as the menu bar draws it, on a plate of the menu bar's own shade: drawn for a dark
/// menu bar, a white icon would vanish on a light page. Without a picture, the app's icon.
private struct MenuBarItemPicture: View {
	static let height = 18.0

	let item: MenuBarHider.Item
	let snapshot: NSImage?

	var body: some View {
		Group {
			if let snapshot {
				Image(nsImage: snapshot)
					.resizable()
					.aspectRatio(contentMode: .fit)
					.frame(height: Self.height)
					.padding(.horizontal, 2)
					.background(
						RoundedRectangle(cornerRadius: 5, style: .continuous)
							.fill(Self.isLight(snapshot) ? SwiftUI.Color.black.opacity(0.75) : SwiftUI.Color.white.opacity(0.9))
					)
			} else if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon {
				Image(nsImage: icon)
					.resizable()
					.frame(width: Self.height, height: Self.height)
			} else {
				Image(systemName: "menubar.rectangle")
					.foregroundStyle(.secondary)
					.frame(width: Self.height, height: Self.height)
			}
		}
		.frame(minWidth: 28)
	}

	/// Whether the item's own pixels are mostly light, the way a dark menu bar draws them.
	private static func isLight(_ image: NSImage) -> Bool {
		guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
		      let context = CGContext(
		      	data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64,
		      	space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		      )
		else { return false }
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 16, height: 8))
		guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }

		var light = 0.0
		var weight = 0.0
		for pixel in 0..<(16 * 8) {
			let alpha = Double(data[pixel * 4 + 3]) / 255
			guard alpha > 0.2 else { continue }
			// Premultiplied: back to the colour before the brightness counts.
			let red = Double(data[pixel * 4]) / 255 / alpha
			let green = Double(data[pixel * 4 + 1]) / 255 / alpha
			let blue = Double(data[pixel * 4 + 2]) / 255 / alpha
			light += (0.299 * red + 0.587 * green + 0.114 * blue) * alpha
			weight += alpha
		}
		return weight > 0 && light / weight > 0.6
	}
}
