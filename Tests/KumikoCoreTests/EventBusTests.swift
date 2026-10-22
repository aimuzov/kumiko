import KumikoCore
import Testing

@MainActor
struct EventBusTests {
	@Test func deliversInSubscriptionOrder() {
		let bus = EventBus()
		var seen: [String] = []

		bus.subscribe { _ in seen.append("first") }
		bus.subscribe { _ in seen.append("second") }
		bus.publish(.configReloaded(Config()))

		#expect(seen == ["first", "second"])
	}

	@Test func unsubscribedHandlerIsNotCalled() {
		let bus = EventBus()
		var count = 0

		let subscription = bus.subscribe { _ in count += 1 }
		bus.unsubscribe(subscription)
		bus.publish(.configReloaded(Config()))

		#expect(count == 0)
	}
}
