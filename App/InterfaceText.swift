import Foundation

enum InterfaceText {
    static func string(_ key: String, locale: Locale, arguments: [CVarArg] = []) -> String {
        let code = locale.language.languageCode?.identifier ?? "en"
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    static func riskReason(_ reason: String, locale: Locale) -> String {
        if let match = reason.wholeMatch(of: /risk (\d+) above (\d+) for a (professional|casual|mixed) chat/),
           let risk = Int(match.1), let cap = Int(match.2) {
            return string("risk %lld above %lld for a %@ chat", locale: locale,
                arguments: [risk, cap, string(String(match.3), locale: locale)])
        }
        if let match = reason.wholeMatch(of: /humor under tension (\d+) in a (professional|casual|mixed) chat/),
           let tension = Int(match.1) {
            return string("humor under tension %lld in a %@ chat", locale: locale,
                arguments: [tension, string(String(match.2), locale: locale)])
        }
        return string(reason, locale: locale)
    }
}
