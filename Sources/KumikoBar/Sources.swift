import AppKit
import Carbon
import IOKit.ps
import IOKit.pwr_mgt

/// Battery charge and power state, from IOKit; nil on a Mac without a battery.
enum Battery {
	struct State: Equatable {
		var percent: Int
		/// On the charger and taking charge.
		var isCharging: Bool
		/// On the charger, charging or not: a full battery, or charging on hold.
		var isPluggedIn: Bool
		var isLowPowerMode: Bool
	}

	static func read() -> State? {
		guard
			let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
			let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
		else { return nil }

		for source in list {
			guard
				let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
				let current = description[kIOPSCurrentCapacityKey] as? Int,
				let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
			else { continue }

			return State(
				percent: current * 100 / max,
				isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
				isPluggedIn: (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
				isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
			)
		}

		return nil
	}

	/// Calls `changed` on the main thread whenever a power source changes.
	@MainActor
	static func observe(_ changed: @escaping @MainActor () -> Void) -> AnyObject? {
		let box = Callback(changed)
		let context = Unmanaged.passRetained(box).toOpaque()

		guard let source = IOPSNotificationCreateRunLoopSource({ context in
			guard let context else { return }
			let box = Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue()
			MainActor.assumeIsolated { box.call() }
		}, context)?.takeRetainedValue() else {
			Unmanaged<Callback>.fromOpaque(context).release()
			return nil
		}

		CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
		return box
	}

	private final class Callback {
		let call: @MainActor () -> Void
		init(_ call: @escaping @MainActor () -> Void) { self.call = call }
	}
}

/// The selected keyboard input source.
enum InputSource {
	static func current() -> String? {
		guard
			let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
			let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
		else { return nil }

		return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
	}

	/// The language of the selected input source as macOS shows it in its own input menu: "EN",
	/// "RU". Nil for a source without a language.
	static func languageCode() -> String? {
		guard
			let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
			let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
			let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String],
			let language = languages.first
		else { return nil }

		return String(language.prefix(2)).uppercased()
	}

	/// Distributed notification macOS posts when the input source changes.
	static let changed = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

	/// The badge the input menu shows in the menu bar for the selected source, "US" or "Ру" in a
	/// rounded frame, as a template image. It comes from the private icon manager the input menu
	/// uses, so it is the system's own picture; nil when that is not there.
	@MainActor
	static func badge() -> NSImage? {
		guard
			let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
			let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
		else { return nil }

		let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
		if let badge = badges[id] { return badge }

		let selector = NSSelectorFromString("titleImageForTISInputSource:")
		guard let manager = iconManager, let method = manager.method(for: selector) else { return nil }

		typealias ImageFor = @convention(c) (AnyObject, Selector, OpaquePointer) -> Unmanaged<NSImage>?
		let image = unsafeBitCast(method, to: ImageFor.self)(
			manager, selector, OpaquePointer(Unmanaged.passUnretained(source).toOpaque())
		)?.takeUnretainedValue()

		image?.isTemplate = true
		badges[id] = image
		return image
	}

	@MainActor private static var badges: [String: NSImage] = [:]

	@MainActor private static let iconManager: NSObject? = {
		let path = "/System/Library/PrivateFrameworks/KeyboardLayouts.framework/KeyboardLayouts"
		guard
			dlopen(path, RTLD_LAZY) != nil,
			let type = NSClassFromString("KLInputSourceIconManager") as? NSObject.Type
		else { return nil }

		let selector = NSSelectorFromString("managerWithAllInputSources")
		guard type.responds(to: selector) else { return nil }
		return type.perform(selector)?.takeUnretainedValue() as? NSObject
	}()
}

/// Keeps the display and the system awake while on, the way `caffeinate -di` does, through power
/// assertions held by kumiko itself: nothing to clean up if kumiko goes away, and no process to
/// keep track of. Whether it is on outlives kumiko in the defaults, like the menu bar's positions.
@MainActor
final class Caffeine {
	private static let key = "caffeinated"
	private let defaults: UserDefaults
	private var assertions: [IOPMAssertionID] = []

	var isOn: Bool { !assertions.isEmpty }

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	func toggle() {
		if isOn { release() } else { hold() }
		defaults.set(isOn, forKey: Self.key)
	}

	/// Turns back on what was on when kumiko quit. The assertions went away with the old process.
	func restore() {
		if !isOn && defaults.bool(forKey: Self.key) { hold() }
	}

	private func release() {
		assertions.forEach { IOPMAssertionRelease($0) }
		assertions = []
	}

	private func hold() {
		for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
			var id = IOPMAssertionID(0)
			let result = IOPMAssertionCreateWithName(
				type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "kumiko caffeinate" as CFString, &id
			)
			if result == kIOReturnSuccess { assertions.append(id) }
		}
	}
}

/// Runs a shell command in the background and hands back the first line it prints.
enum Shell {
	static func firstLine(of command: String, completion: @escaping @MainActor @Sendable (String) -> Void) {
		DispatchQueue.global(qos: .utility).async {
			let process = Process()
			let pipe = Pipe()
			process.executableURL = URL(filePath: "/bin/sh")
			process.arguments = ["-c", command]
			process.standardOutput = pipe
			process.standardError = FileHandle.nullDevice

			var line = ""
			if (try? process.run()) != nil {
				let data = pipe.fileHandleForReading.readDataToEndOfFile()
				process.waitUntilExit()
				line = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
			}

			DispatchQueue.main.async { MainActor.assumeIsolated { completion(line) } }
		}
	}
}
