import Foundation
import VQMetrixCore

enum DocumentationLinks {
    static func scores(_ language: AppLanguage) -> URL {
        let article = language.code == "ja" ? "understandingvmaf-japanese" : "understandingvmaf"
        return URL(string: "https://haishinkit.github.io/VQMetrix/swift/documentation/vqmetrixcore/\(article)/")!
    }
}
