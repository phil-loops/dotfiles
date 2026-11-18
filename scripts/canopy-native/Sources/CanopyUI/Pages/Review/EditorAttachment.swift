import CanopyCore
import Foundation

struct EditorAttachment: Decodable, Equatable {
    let script: String
    let record: String
    let token: String

    func belongs(to lease: String) -> Bool {
        script.hasPrefix("/") && URL(fileURLWithPath: script).lastPathComponent == "canopy-editor"
            && record.hasPrefix("/") && URL(fileURLWithPath: record).lastPathComponent == "session.json"
            && URL(fileURLWithPath: record).deletingLastPathComponent().lastPathComponent == lease
            && UUID(uuidString: token) != nil
    }

    func arguments(position: String) -> [String] {
        Zsh.arguments("exec python3 \"$0\" \"$1\" \"$2\" \"$3\"", [script, record, token, position])
    }
}
