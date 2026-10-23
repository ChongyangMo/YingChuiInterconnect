import Foundation

public enum YingchuiService {
    public static let bonjourType = "_yingchui._tcp"
    public static let protocolVersion = 9
    public static let maximumFrameSize = 4_194_304
}

public enum WireMessageKind: String, Codable, Sendable {
    case hello
    case pairRequest
    case pairResult
    case ping
    case pong
    case pointerMove
    case cursorState
    case touchInput
    case pointerReturn
    case displayState
    case mouseButton
    case scroll
    case textInput
    case keyPress
    case keyboardLanguage
    case clipboardGet
    case clipboardSet
    case clipboardResult
    case controlAck
    case streamStart
    case streamStop
    case videoConfig
    case keyframeRequest
    case streamStats
    case heartbeat
    case accountLink
    case error
}

public enum PointerButton: String, Codable, Hashable, Sendable {
    case left
    case right
}

public enum RemoteKey: String, Codable, CaseIterable, Sendable {
    case escape
    case returnKey
    case tab
    case space
    case deleteBackward
    case deleteForward
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown
    case letterA
    case letterC
    case letterV
    case letterW
    case letterX
    case letterZ
    case letterB
    case letterD
    case letterE
    case letterF
    case letterG
    case letterH
    case letterI
    case letterJ
    case letterK
    case letterL
    case letterM
    case letterN
    case letterO
    case letterP
    case letterQ
    case letterR
    case letterS
    case letterT
    case letterU
    case letterY
    case digit0
    case digit1
    case digit2
    case digit3
    case digit4
    case digit5
    case digit6
    case digit7
    case digit8
    case digit9
    case minus
    case equal
    case leftBracket
    case rightBracket
    case backslash
    case semicolon
    case quote
    case grave
    case comma
    case period
    case slash
}

public enum RemoteKeyboardLanguage: String, Codable, Sendable {
    case english
    case pinyin
}

public enum RemoteKeyModifier: String, Codable, CaseIterable, Sendable {
    case command
    case option
    case control
    case shift
}

public struct WireMessage: Codable, Equatable, Sendable {
    public var version: Int
    public let id: UUID
    public let kind: WireMessageKind
    public let sentAtMilliseconds: UInt64
    public let deviceName: String?
    public let deviceID: String?
    public let hostID: String?
    public let pairingCode: String?
    public let accepted: Bool?
    public let deltaX: Double?
    public let deltaY: Double?
    public let button: PointerButton?
    public let pressed: Bool?
    public let text: String?
    public let key: RemoteKey?
    public let modifiers: [RemoteKeyModifier]?
    public let keyboardLanguage: RemoteKeyboardLanguage?
    public let detail: String?
    public let errorMessage: String?
    public let audioPort: Int?
    public let audioEnabled: Bool?
    public let videoPort: Int?
    public let streamID: UUID?
    public let codec: String?
    public let width: Int?
    public let height: Int?
    public let viewportWidth: Int?
    public let viewportHeight: Int?
    public let frameRate: Int?
    public let bitRate: Int?
    public let receiverUsesWiFi: Bool?
    public let parameterSets: [String]?
    public let packetsReceived: UInt64?
    public let framesDecoded: UInt64?
    public let framesDropped: UInt64?
    public let networkFramesMissing: UInt64?
    public let sessionToken: String?
    public let displayMode: RemoteDisplayMode?
    public let displayPlacement: RemoteDisplayPlacement?
    public let displayState: RemoteDisplayState?
    public let touch: RemoteTouchInput?
    public let supportsTouch: Bool?
    public let supportsTouchHover: Bool?
    public let supportsAccountLink: Bool?
    public let accountLink: AccountLinkMessage?
    public let videoKey: String?
    public let supportsVideoRepair: Bool?
    public let videoRepair: VideoRepairRequest?
    public let supportsCursor: Bool?
    public let cursorState: RemoteCursorState?
    public let cursorInput: RemoteCursorInput?
    public let minimumProtocolVersion: Int?
    public let videoCapabilities: [VideoDecodeCapability]?

    public init(
        version: Int = YingchuiService.protocolVersion,
        id: UUID = UUID(),
        kind: WireMessageKind,
        sentAtMilliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000),
        deviceName: String? = nil,
        deviceID: String? = nil,
        hostID: String? = nil,
        pairingCode: String? = nil,
        accepted: Bool? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        button: PointerButton? = nil,
        pressed: Bool? = nil,
        text: String? = nil,
        key: RemoteKey? = nil,
        modifiers: [RemoteKeyModifier]? = nil,
        keyboardLanguage: RemoteKeyboardLanguage? = nil,
        detail: String? = nil,
        errorMessage: String? = nil,
        audioPort: Int? = nil,
        audioEnabled: Bool? = nil,
        videoPort: Int? = nil,
        streamID: UUID? = nil,
        codec: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        viewportWidth: Int? = nil,
        viewportHeight: Int? = nil,
        frameRate: Int? = nil,
        bitRate: Int? = nil,
        receiverUsesWiFi: Bool? = nil,
        parameterSets: [String]? = nil,
        packetsReceived: UInt64? = nil,
        framesDecoded: UInt64? = nil,
        framesDropped: UInt64? = nil,
        sessionToken: String? = nil,
        displayMode: RemoteDisplayMode? = nil,
        displayPlacement: RemoteDisplayPlacement? = nil,
        displayState: RemoteDisplayState? = nil,
        videoKey: String? = nil,
        touch: RemoteTouchInput? = nil,
        supportsTouch: Bool? = nil,
        supportsTouchHover: Bool? = nil,
        supportsAccountLink: Bool? = nil,
        accountLink: AccountLinkMessage? = nil,
        supportsVideoRepair: Bool? = nil,
        videoRepair: VideoRepairRequest? = nil,
        networkFramesMissing: UInt64? = nil,
        supportsCursor: Bool? = nil,
        cursorState: RemoteCursorState? = nil,
        cursorInput: RemoteCursorInput? = nil,
        minimumProtocolVersion: Int? = nil,
        videoCapabilities: [VideoDecodeCapability]? = nil
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.sentAtMilliseconds = sentAtMilliseconds
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.hostID = hostID
        self.pairingCode = pairingCode
        self.accepted = accepted
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.button = button
        self.pressed = pressed
        self.text = text
        self.key = key
        self.modifiers = modifiers
        self.keyboardLanguage = keyboardLanguage
        self.detail = detail
        self.errorMessage = errorMessage
        self.audioPort = audioPort
        self.audioEnabled = audioEnabled
        self.videoPort = videoPort
        self.streamID = streamID
        self.codec = codec
        self.width = width
        self.height = height
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.frameRate = frameRate
        self.bitRate = bitRate
        self.receiverUsesWiFi = receiverUsesWiFi
        self.parameterSets = parameterSets
        self.packetsReceived = packetsReceived
        self.framesDecoded = framesDecoded
        self.framesDropped = framesDropped
        self.sessionToken = sessionToken
        self.displayMode = displayMode
        self.displayPlacement = displayPlacement
        self.displayState = displayState
        self.videoKey = videoKey
        self.touch = touch
        self.supportsTouch = supportsTouch
        self.supportsTouchHover = supportsTouchHover
        self.supportsAccountLink = supportsAccountLink
        self.accountLink = accountLink
        self.supportsVideoRepair = supportsVideoRepair
        self.videoRepair = videoRepair
        self.networkFramesMissing = networkFramesMissing
        self.supportsCursor = supportsCursor
        self.cursorState = cursorState
        self.cursorInput = cursorInput
        self.minimumProtocolVersion = minimumProtocolVersion
        self.videoCapabilities = videoCapabilities
    }
}
