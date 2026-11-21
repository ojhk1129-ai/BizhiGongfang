import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Live Photo 配对元数据的写法。
///
/// 一张 Live Photo = 一张静态图（JPEG）+ 一段视频（MOV），两者靠同一个
/// content identifier（UUID 字符串）配对：
/// - JPEG：在 kCGImagePropertyMakerAppleDictionary 里用键 "17" 写 identifier。
/// - MOV：顶层 QuickTime 元数据 com.apple.quicktime.content.identifier（UTF-8），
///   写在 AVAssetWriter.metadata 里。
/// - still-image-time：注意，它不是顶层元数据项，而是一条定时元数据轨道
///   （timed metadata track）里的一个样本，样本的时间戳就是静态图在视频里的
///   时刻，样本内容只是一个 0xFF 字节（会被系统忽略）。
///   权威实现（LimitPoint/LivePhoto、flutter_photo_manager）都是这么做的：
///   AVAssetWriterInput(mediaType: .metadata) + AVAssetWriterInputMetadataAdaptor，
///   用 AVTimedMetadataGroup 在静态图时刻写一个样本。
///   只写顶层元数据项的写法在现在的系统上配对不上，所以这里不用。
enum LivePhotoMetadata {

    /// 生成一个新的 content identifier。
    static func newIdentifier() -> String {
        UUID().uuidString
    }

    /// MOV 顶层元数据：content identifier（UTF-8 字符串）。
    /// identifier 用 .quickTimeMetadataContentIdentifier。
    static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.value = identifier as NSString
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        return item
    }

    /// 把 UIImage 写成带 content identifier 的 JPEG 数据。
    /// identifier 写在 MakerApple 字典的 "17" 号键里。
    static func jpegData(for image: UIImage, identifier: String) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let properties: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality as String: 0.92
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 创建 still-image-time 定时元数据轨道的输入 + 适配器。
    /// 轨道的格式描述：mdta/com.apple.quicktime.still-image-time，int8。
    static func makeStillImageTimeTrack() -> (AVAssetWriterInput, AVAssetWriterInputMetadataAdaptor)? {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8 as String
        ]
        var formatDescription: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let desc = formatDescription else { return nil }
        let input = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: desc
        )
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        return (input, adaptor)
    }

    /// 在静态图时刻写一个 still-image-time 样本。
    /// 样本内容是一个 0xFF 字节（系统会忽略内容，只看样本的时间戳）。
    /// identifier 是 "mdta/com.apple.quicktime.still-image-time"（用 rawValue 写，系统没有现成的常量；必须带 mdta/ 前缀，否则 setIdentifier 会报 Bad identifier）。
    static func stillImageTimeGroup(at time: TimeInterval) -> AVTimedMetadataGroup {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
        item.value = NSNumber(value: Int8(-1))
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        let timeRange = CMTimeRange(
            start: CMTime(seconds: time, preferredTimescale: 600),
            duration: CMTime(value: 1, timescale: 30)
        )
        return AVTimedMetadataGroup(items: [item], timeRange: timeRange)
    }
}
