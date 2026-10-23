import AVFoundation
import Foundation
import YingchuiProtocol

enum VideoFormatDescriptionFactory {
    static func make(codec: VideoCodec, parameterSets: [Data]) throws -> CMVideoFormatDescription {
        let count = codec == .hevc ? 3 : 2
        guard parameterSets.count >= count, parameterSets.prefix(count).allSatisfy({ !$0.isEmpty }) else {
            throw VideoRendererError.missingParameterSets
        }
        // NSData 保持参数集内存存活，直到 CoreMedia 完成同步拷贝。
        let retained = parameterSets.prefix(count).map { $0 as NSData }
        let pointers = retained.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = retained.map(\.length)
        var description: CMFormatDescription?
        let status = withExtendedLifetime(retained) {
            if codec == .hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { throw VideoRendererError.formatDescription(status) }
        return description
    }
}
