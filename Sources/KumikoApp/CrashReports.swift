import KumikoCore
import Sentry

/// Crash reports to Sentry, on unless `[telemetry] crash_reports = false`. Follows the config as it
/// reloads, so turning them off takes effect without a restart.
@MainActor
enum CrashReports {
	/// Public by design: a DSN only lets a client send events to this one project.
	private static let dsn = "https://2dcb0fa8ad8fb8f30bc8f71c033729d8@o4512327275315200.ingest.de.sentry.io/4512328872099920"

	static func apply(_ telemetry: Config.Telemetry) {
		guard telemetry.crashReports != SentrySDK.isEnabled else { return }

		guard telemetry.crashReports else {
			SentrySDK.close()
			return
		}

		SentrySDK.start { options in
			options.dsn = dsn
			options.releaseName = "kumiko@\(Kumiko.version)"
			#if DEBUG
				options.environment = "development"
			#else
				options.environment = "production"
			#endif

			options.sendDefaultPii = false
			options.enableUncaughtNSExceptionReporting = true
			// Breadcrumbs would carry what kumiko saw happen: apps launching, windows, titles.
			options.enableAutoBreadcrumbTracking = false
			options.enableCaptureFailedRequests = false
			// Accessibility calls stall on a busy app all the time; as hangs they are noise.
			options.enableAppHangTracking = false
			options.beforeSend = { event in
				// The host name is the Mac's name, which is often its owner's.
				event.serverName = nil
				return event
			}
		}
	}
}
