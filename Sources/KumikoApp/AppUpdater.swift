import AppKit
import Combine
import KumikoCore
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation, SPUStandardUserDriverDelegate {
	let isAvailable = UpdateConfiguration(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary ?? [:]) != nil
	@Published private(set) var canCheckForUpdates = false
	@Published private(set) var automaticallyChecksForUpdates = false
	var onInteractionChanged: () -> Void = {}
	var needsKeyboard: Bool {
		guard NSApplication.shared.isActive else { return false }
		if isShowingModalAlert { return true }
		guard let window = NSApplication.shared.keyWindow, window.isKeyWindow,
			let windowController = window.windowController
		else { return false }
		return Bundle(for: type(of: windowController)).bundleURL == Bundle(for: SPUStandardUpdaterController.self).bundleURL
	}

	private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
	private var observations: [NSKeyValueObservation] = []
	private var activityObservation: AnyCancellable?
	private var isShowingModalAlert = false

	func start() {
		guard isAvailable, observations.isEmpty else { return }
		let updater = controller.updater
		observations = [
			updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
				MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
			},
			updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
				MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
			},
		]
		activityObservation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
			.merge(with: NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
			.merge(with: NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification))
			.merge(with: NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification))
			.sink { [weak self] _ in MainActor.assumeIsolated { self?.onInteractionChanged() } }
		controller.startUpdater()
	}

	func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
		guard isAvailable else { return }
		controller.updater.automaticallyChecksForUpdates = enabled
	}

	@objc func checkForUpdates(_ sender: Any?) {
		guard canCheckForUpdates else { return }
		controller.checkForUpdates(sender)
	}

	func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }

	nonisolated func standardUserDriverWillShowModalAlert() {
		MainActor.assumeIsolated {
			isShowingModalAlert = true
			onInteractionChanged()
		}
	}

	nonisolated func standardUserDriverDidShowModalAlert() {
		MainActor.assumeIsolated {
			isShowingModalAlert = false
			onInteractionChanged()
		}
	}
}
