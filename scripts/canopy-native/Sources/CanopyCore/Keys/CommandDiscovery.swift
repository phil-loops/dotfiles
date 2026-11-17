import Foundation

public enum CommandDiscovery {
    public struct Entry {
        public let command: Command
        public let searchText: String
    }

    public static func entries(_ eligible: [Command]) -> [Entry] {
        let commands = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        func representative(_ command: Command) -> Command {
            guard command.keys.isEmpty, let canonical = command.aliasFor, let target = commands[canonical],
                  target.aliasFor == nil, target.takes == command.takes, target.needsArg == command.needsArg else { return command }
            return target
        }
        var terms: [String: [String]] = [:]
        for command in eligible {
            terms[representative(command).id, default: []].append("\(command.id) \(command.title)")
        }
        return eligible.compactMap { command in
            guard representative(command).id == command.id else { return nil }
            return Entry(command: command, searchText: terms[command.id, default: []].joined(separator: " "))
        }
    }
}
