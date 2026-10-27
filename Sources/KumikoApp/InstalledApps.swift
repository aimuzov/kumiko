import AppKit

/// The apps of this Mac, for the recommended settings to place only what is there.
enum InstalledApps {
	/// The folders apps live in, and Finder's, which is no app of /Applications.
	private static let folders = [
		"/Applications", "/System/Applications", "/System/Library/CoreServices",
		NSHomeDirectory() + "/Applications",
	]

	/// Every name an app is known by, its file name, its name in Finder and the names in its
	/// Info.plist, to the name kumiko sees it under: what a running app reports as its
	/// `localizedName`. Telegram Desktop.app is `Telegram`, Things3.app `Things`, and Photos on a Mac
	/// in Russian `Фото`. Folders are looked into one level down, for /Applications/Utilities and
	/// the folders of app suites.
	static func names() -> [String: String] {
		var names: [String: String] = [:]
		let files = FileManager.default

		func add(_ url: URL) {
			let file = url.deletingPathExtension().lastPathComponent
			let finder = files.displayName(atPath: url.path(percentEncoded: false))
			let bundle = Bundle(url: url)
			let localized = bundle?.localizedInfoDictionary ?? [:]
			let plain = bundle?.infoDictionary ?? [:]
			// How macOS picks `localizedName`, checked against the running apps: the translated names
			// only for a bundle that says it has them. zoom.us.app translates its name to Zoom without
			// saying so, and stays `zoom.us`.
			let translated = (plain["LSHasLocalizedDisplayName"] as? NSNumber)?.boolValue
				?? (plain["LSHasLocalizedDisplayName"] as? String).map { ["1", "yes", "true"].contains($0.lowercased()) }
				?? false
			let ownNames = [plain["CFBundleDisplayName"], plain["CFBundleName"]]
			let plist = ((translated ? [localized["CFBundleDisplayName"], localized["CFBundleName"]] : []) + ownNames)
				.compactMap { $0 as? String }.filter { !$0.isEmpty }
			let seen = plist.first ?? file
			let aliases = [file, finder.hasSuffix(".app") ? String(finder.dropLast(4)) : finder] + plist
			for alias in aliases where names[alias] == nil {
				names[alias] = seen
			}
		}

		for folder in folders {
			let url = URL(filePath: folder, directoryHint: .isDirectory)
			for item in (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
				if item.pathExtension == "app" {
					add(item)
				} else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
					for inner in (try? files.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
					where inner.pathExtension == "app" {
						add(inner)
					}
				}
			}
		}

		// kumiko itself, wherever it was started from.
		add(Bundle.main.bundleURL)
		return names
	}
}
