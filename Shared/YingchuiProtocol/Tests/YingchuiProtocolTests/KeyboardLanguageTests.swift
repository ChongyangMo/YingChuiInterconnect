import Testing
@testable import YingchuiProtocol

@Test func keyboardLanguageRoundTripsAndRequiresLanguage() throws {
    let message = WireMessage(kind: .keyboardLanguage, keyboardLanguage: .pinyin)
    var decoder = WireMessageDecoder()
    #expect(try decoder.append(WireCodec.encode(message)) == [message])
    #expect(try RemoteControlValidator.command(from: message) == .keyboardLanguage(.pinyin))
    #expect(throws: RemoteControlValidationError.missingField) {
        try RemoteControlValidator.command(from: WireMessage(kind: .keyboardLanguage))
    }
}

@Test func pinyinUsesPhysicalLettersAndCandidateSelectionKeys() {
    let keys = "nihao 1234567890".compactMap { RemoteKeyboardStroke(character: $0)?.key }
    #expect(keys == [.letterN, .letterI, .letterH, .letterA, .letterO, .space,
                     .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9, .digit0])
    #expect(RemoteKeyboardStroke(character: "N")?.modifiers == [.shift])
    #expect(RemoteKeyboardStroke(character: "?")?.key == .slash)
    #expect(RemoteKeyboardStroke(character: "?")?.modifiers == [.shift])
    #expect(RemoteKeyboardStroke(character: "你") == nil)
}

@Test func everyVirtualLatinLetterHasAUniquePhysicalKey() {
    let keys = "abcdefghijklmnopqrstuvwxyz".compactMap { RemoteKeyboardStroke(character: $0)?.key }
    #expect(keys.count == 26)
    #expect(Set(keys).count == 26)
}
