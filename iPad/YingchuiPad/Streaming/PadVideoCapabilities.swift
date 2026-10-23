import CoreMedia
import VideoToolbox
import YingchuiProtocol

enum PadVideoCapabilities {
    static func current(maximumFrameRate: Int) -> [VideoDecodeCapability] {
        var offers = [VideoDecodeCapability(codec: .h264, maximumFrameRate: maximumFrameRate)]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            offers.append(VideoDecodeCapability(codec: .hevc, maximumFrameRate: maximumFrameRate))
        }
        return offers
    }
}

extension PadConnectionModel {
    func disableHEVC(reason: String, beforeConfiguration: Bool = false) {
        let offered = requestedVideoCapabilities.value.contains { $0.codec == VideoCodec.hevc.rawValue }
        guard (activeVideoCodec.value == .hevc || (beforeConfiguration && offered)), !hevcDisabled.value else { return }
        hevcDisabled.set(true)
        eventLog.record("当前连接停用 HEVC，恢复时改用 H.264：\(reason)")
    }
}
