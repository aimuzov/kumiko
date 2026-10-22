import Foundation

/// Calls back when anything in the config directory changes.
///
/// It watches the directory rather than the file: editors save by writing a temporary file and
/// renaming it over the old one, which leaves a watch on the file itself pointing at a deleted
/// inode after the first save.
@MainActor
public final class ConfigWatcher {
	private let directory: URL
	private let onChange: @MainActor () -> Void
	private var source: (any DispatchSourceFileSystemObject)?
	private var pending: DispatchWorkItem?

	public init(directory: URL, onChange: @escaping @MainActor () -> Void) {
		self.directory = directory
		self.onChange = onChange
	}

	public func start() throws {
		// Creating the directory up front means a config written later is noticed without a restart.
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

		let fd = open(directory.path(percentEncoded: false), O_EVTONLY)
		guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }

		let source = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: fd,
			eventMask: [.write, .delete, .rename],
			queue: .main
		)

		source.setEventHandler { [weak self] in
			MainActor.assumeIsolated { self?.handle(source.data) }
		}
		source.setCancelHandler { close(fd) }
		source.resume()

		self.source = source
	}

	public func stop() {
		pending?.cancel()
		source?.cancel()
		source = nil
	}

	private func handle(_ events: DispatchSource.FileSystemEvent) {
		// The directory itself went away or was moved: the descriptor now watches nothing, so start
		// over on the path, which also recreates the directory.
		if events.contains(.delete) || events.contains(.rename) {
			stop()
			try? start()
		}

		// One save is several directory events in a row; reload once after they settle.
		pending?.cancel()
		let item = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated { self?.onChange() }
		}
		pending = item
		DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: item)
	}
}
