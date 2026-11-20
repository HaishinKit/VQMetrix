import Foundation

package enum AppLanguage: String, CaseIterable, Sendable {
    case system, english, japanese
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("VQMetrix_VQMetrixCore.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
    package var code: String {
        switch self {
        case .system: Locale.preferredLanguages.first?.hasPrefix("ja") == true ? "ja" : "en"
        case .english: "en"
        case .japanese: "ja"
        }
    }
    package var locale: Locale { Locale(identifier: code) }
    package func text(_ key: String, _ arguments: String...) -> String { format(key, arguments: arguments) }
    package func format(_ key: String, arguments: [String]) -> String {
        let path = Self.resources.path(forResource: code, ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:)) ?? Self.resources
        let template = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: locale, arguments: arguments.map { $0 as any CVarArg })
    }
}
