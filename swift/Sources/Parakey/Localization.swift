import Foundation

enum InterfaceLanguage: String, CaseIterable {
    case russian = "ru"
    case english = "en"
}

func localizedText(_ russian: String,
                   _ english: String,
                   language: InterfaceLanguage) -> String {
    language == .russian ? russian : english
}
