import Foundation
import KumikoCore
import Testing

/// `[[wm.rule]]`: an array of tables whose name is a path, next to the `[wm]` table it lives under.
struct RuleArrayWriterTests {
	private let text = """
		[wm]
		manage = false

		[[wm.rule]]
		app = "Code|Zed"
		manage = true

		[[wm.rule]]
		app = "Mail"
		manage = true

		[[wm.rule]]
		app = "Mail"
		title = "General|Accounts"
		manage = false

		# Workspaces.

		[[workspace]]
		name = "Code"
		"""

	@Test func changesAKeyOfOneRule() throws {
		let changed = try ConfigWriter.apply(
			ConfigEdit(target: .entry("wm.rule", 1), key: "manage", value: .bool(false)), to: text
		)
		#expect(changed == text.replacingOccurrences(
			of: "app = \"Mail\"\nmanage = true", with: "app = \"Mail\"\nmanage = false"
		))
	}

	@Test func removesAKeyOfOneRule() throws {
		let changed = try ConfigWriter.apply(ConfigEdit(target: .entry("wm.rule", 2), key: "title", value: nil), to: text)
		#expect(changed == text.replacingOccurrences(of: "title = \"General|Accounts\"\n", with: ""))
	}

	@Test func leavesTheRulesOutOfTheWmTable() throws {
		let changed = try ConfigWriter.apply(ConfigEdit(target: .table("wm"), key: "manage", value: .bool(true)), to: text)
		#expect(changed == text.replacingOccurrences(of: "[wm]\nmanage = false", with: "[wm]\nmanage = true"))
	}

	@Test func insertsARuleAfterTheLastOne() throws {
		let insert = EntryEdit.insert("wm.rule", fields: [.init("app", .string("Arc")), .init("manage", .bool(true))])
		#expect(try ConfigWriter.apply(insert, to: text) == text.replacingOccurrences(
			of: "manage = false\n\n# Workspaces.",
			with: "manage = false\n\n[[wm.rule]]\napp = \"Arc\"\nmanage = true\n\n# Workspaces."
		))
	}

	@Test func insertsTheFirstRuleAtTheEnd() throws {
		let insert = EntryEdit.insert("wm.rule", fields: [.init("app", .string("Arc")), .init("manage", .bool(true))])
		#expect(try ConfigWriter.apply(insert, to: "[wm]\nmanage = false\n")
			== "[wm]\nmanage = false\n\n[[wm.rule]]\napp = \"Arc\"\nmanage = true\n")
	}

	@Test func movesAndRemovesRules() throws {
		let moved = try ConfigWriter.apply(EntryEdit.move("wm.rule", from: 2, to: 0), to: text)
		let rules = try Config.parse(moved).wm.rules
		#expect(rules.map(\.title) == ["General|Accounts", nil, nil])

		let removed = try ConfigWriter.apply(EntryEdit.remove("wm.rule", 0), to: text)
		#expect(try Config.parse(removed).wm.rules.map(\.app) == ["Mail", "Mail"])
		#expect(try Config.parse(removed).workspaces.map(\.name) == ["Code"])
	}

	@Test func refusesRulesWrittenInline() {
		#expect(throws: ConfigError.self) {
			try ConfigWriter.apply(EntryEdit.remove("wm.rule", 0), to: "[wm]\nrule = [{ app = \"Code\", manage = true }]\n")
		}
		#expect(throws: ConfigError.self) {
			try ConfigWriter.apply(EntryEdit.remove("wm.rule", 0), to: "wm = { manage = true }\n")
		}
	}
}
