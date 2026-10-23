import Foundation

/// 拼音必须传递真实按键，Unicode 注入只用于已经确认的文字。
public struct RemoteKeyboardStroke: Equatable, Sendable {
    public let key: RemoteKey
    public let modifiers: [RemoteKeyModifier]

    public init?(character: Character) {
        let text = String(character)
        if let key = Self.plain[text.lowercased()] {
            self.key = key
            modifiers = text != text.lowercased() ? [.shift] : []
        } else if let key = Self.shifted[text] {
            self.key = key
            modifiers = [.shift]
        } else { return nil }
    }

    private static let plain: [String: RemoteKey] = [
        "a":.letterA,"b":.letterB,"c":.letterC,"d":.letterD,"e":.letterE,"f":.letterF,"g":.letterG,
        "h":.letterH,"i":.letterI,"j":.letterJ,"k":.letterK,"l":.letterL,"m":.letterM,"n":.letterN,
        "o":.letterO,"p":.letterP,"q":.letterQ,"r":.letterR,"s":.letterS,"t":.letterT,"u":.letterU,
        "v":.letterV,"w":.letterW,"x":.letterX,"y":.letterY,"z":.letterZ,
        "0":.digit0,"1":.digit1,"2":.digit2,"3":.digit3,"4":.digit4,"5":.digit5,"6":.digit6,
        "7":.digit7,"8":.digit8,"9":.digit9,"-":.minus,"=":.equal,"[":.leftBracket,
        "]":.rightBracket,"\\":.backslash,";":.semicolon,"'":.quote,"`":.grave,",":.comma,".":.period,"/":.slash,
        " ":.space,"\n":.returnKey,"\t":.tab
    ]
    private static let shifted: [String: RemoteKey] = [
        "!":.digit1,"@":.digit2,"#":.digit3,"$":.digit4,"%":.digit5,"^":.digit6,"&":.digit7,
        "*":.digit8,"(":.digit9,")":.digit0,"_":.minus,"+":.equal,"{":.leftBracket,"}":.rightBracket,
        "|":.backslash,":":.semicolon,"\"":.quote,"~":.grave,"<":.comma,">":.period,"?":.slash
    ]
}
