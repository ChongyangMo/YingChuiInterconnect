import CoreMedia
import Foundation
import VideoToolbox
import YingchuiProtocol

enum MacVideoCodecSupport {
    private static let cache = SynchronizedValue<[StreamDimensions: Bool]>([:])

    static func canEncodeHEVC(_ requested: StreamDimensions) -> Bool {
        let size = VideoOutputSizingPolicy.normalizedRequest(requested)
        if let available = cache.value[size] { return available }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(size.width), height: Int32(size.height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &session)
        let available = status == noErr && session != nil
        if let session { VTCompressionSessionInvalidate(session) }
        cache.mutate { $0[size] = available }
        return available
    }
}

extension MacScreenStreamer {
    func extractParameterSets(from format: CMFormatDescription) -> [Data]? {
        var count = 0
        let hevc = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        guard status == noErr, count >= (hevc ? 3 : 2) else { return nil }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let result: OSStatus
            if hevc {
                result = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            guard result == noErr, let pointer, size > 0 else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }
}
