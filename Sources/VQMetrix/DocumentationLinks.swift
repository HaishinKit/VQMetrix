import Foundation

enum DocumentationLinks {
    static func scores(_ language: AppLanguage) -> URL {
        let prefix = language.code == "ja" ? "ja/swift" : "swift"
        return URL(string: "https://haishinkit.github.io/VQMetrix/\(prefix)/documentation/vqmetrix/understandingvmaf/")!
    }
}
