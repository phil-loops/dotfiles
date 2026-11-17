import Testing
@testable import CanopyCore

@MainActor struct CommandDiscoveryTests {
    func command(_ id: String, alias: String? = nil, takes: String? = nil) -> Command {
        var command = Command(id: id, title: id, scope: .global, takes: takes)
        command.aliasFor = alias
        return command
    }

    @Test func compatibilityNamesContributeSearchTermsToOneCanonicalChoice() {
        let canonical = command("parent"), alias = command("review.parent", alias: "parent")
        let entries = CommandDiscovery.entries([alias, canonical])
        #expect(entries.map(\.command.id) == ["parent"])
        #expect(entries.first?.searchText.contains("review.parent") == true)
        #expect(!entries[0].searchText.contains("forest.parent"))
    }

    @Test func aMissingCanonicalOrMalformedCycleCannotHideAnAction() {
        #expect(CommandDiscovery.entries([command("review.parent", alias: "parent")]).map(\.command.id) == ["review.parent"])
        let cycle = [command("one", alias: "two"), command("two", alias: "one")]
        #expect(CommandDiscovery.entries(cycle).map(\.command.id) == ["one", "two"])
    }

    @Test func differentArgumentsOrAnActualAliasKeyRetainTheirOwnChoice() {
        let canonical = command("parent")
        let argument = command("argument", alias: "parent", takes: "text")
        var keyed = command("keyed", alias: "parent")
        keyed.keysByMode = [.normal: ["x"]]
        #expect(CommandDiscovery.entries([canonical, argument, keyed]).map(\.command.id) == ["parent", "argument", "keyed"])
    }

    @Test func registryMetadataWorksBeforeAndAfterPageRegistration() {
        let registry = CommandRegistry()
        registry.register(command("parent"))
        registry.register(command("forest.parent"))
        registry.alias(["forest.parent", "review.parent"], to: "parent")
        registry.register(command("review.parent"))
        #expect(registry.command("forest.parent")?.aliasFor == "parent")
        #expect(registry.command("review.parent")?.aliasFor == "parent")
        #expect(registry.command("parent")?.aliasFor == nil)
    }
}
