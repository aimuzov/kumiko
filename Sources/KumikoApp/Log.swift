import KumikoCore
import os

enum Log {
	static let app = Logger(subsystem: Kumiko.bundleIdentifier, category: "app")
	static let config = Logger(subsystem: Kumiko.bundleIdentifier, category: "config")
	static let ipc = Logger(subsystem: Kumiko.bundleIdentifier, category: "ipc")
}
