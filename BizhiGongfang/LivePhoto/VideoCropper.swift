import AVFoundation
import CoreMedia
import UIKit

/// 视频壁纸：把相册视频裁剪到 12 秒，写好 Live Photo 配对元数据。
enum VideoCropper {

    enum CropError: LocalizedError {
        case invalidDuration
        case exportSessionUnavailable
        case exportFailed(Error?)
        case noVideoTrack
        case noFormatDescription
        case metadataTrackFailed
        case cannotAddInput
        case appendFailed(Error?)
        case writeFailed(Error?)
        case readFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .invalidDuration: return "视频时长无效"
            case .exportSessionUnavailable: return "无法创建导出会话"
            case .exportFailed(let error): return "视频裁剪失败：\(error?.localizedDescription ?? "未知错误")"
            case .noVideoTrack: return "视频里没有画面轨道"
            case .noFormatDescription: return "无法读取视频格式"
            case .metadataTrackFailed: return "无法创建元数据轨道"
            case .cannotAddInput: return "无法添加视频输入"
            case .appendFailed(let error): return "写入视频帧失败：\(error?.localizedDescription ?? "未知错误")"
            case .writeFailed(let error): return "视频写入失败：\(error?.localizedDescription ?? "未知错误")"
            case .readFailed(let error): return "读取视频失败：\(error?.localizedDescription ?? "未知错误")"
            }
        }
    }

    /// 裁剪并写好元数据。返回最终的 MOV 地址和静态图时刻（裁剪后视频的一半）。
    /// completion 在任意队列回调，调用方要自己切回主线程更新界面。
    static func cropToLivePhoto(
        sourceURL: URL,
        identifier: String,
        completion: @escaping (Result<(videoURL: URL, stillImageTime: Double), Error>) -> Void
    ) {
        Task {
            do {
                let asset = AVURLAsset(url: sourceURL)
                let duration = try await asset.load(.duration)
                let totalSeconds = CMTimeGetSeconds(duration)
                guard totalSeconds > 0, totalSeconds.isFinite else {
                    throw CropError.invalidDuration
                }
                // 超过 12 秒取中间 12 秒，不足 12 秒用全长
                let trimLength = min(totalSeconds, 12.0)
                let trimStart = max(0, (totalSeconds - trimLength) / 2)
                let stillTime = trimLength / 2
                // 第一步：AVAssetExportSession 裁剪，同时写 content identifier
                let trimmedURL = try await exportTrimmed(
                    asset: asset, start: trimStart, length: trimLength, identifier: identifier
                )
                // 第二步：AVAssetExportSession 写不了 still-image-time 定时轨道，
                // 这里直通重封装一次补上（不重新编码，只复制视频样本）
                let finalURL = try await addStillImageTimeTrack(
                    sourceURL: trimmedURL, identifier: identifier, stillTime: stillTime
                )
                completion(.success((finalURL, stillTime)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// 从视频里取指定时刻的一帧（已按拍摄方向转正，最大 1080x1920）。
    static func stillImage(from videoURL: URL, at time: TimeInterval) async throws -> UIImage {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1080, height: 1920)
        let cgImage = try generator.copyCGImage(
            at: CMTime(seconds: time, preferredTimescale: 600),
            actualTime: nil
        )
        return UIImage(cgImage: cgImage)
    }

    // MARK: - 第一步：AVAssetExportSession 裁剪

    private static func exportTrimmed(
        asset: AVAsset,
        start: TimeInterval,
        length: TimeInterval,
        identifier: String
    ) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CropError.exportSessionUnavailable
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )
        session.metadata = [LivePhotoMetadata.contentIdentifierItem(identifier)]
        await session.export()
        guard session.status == .completed else {
            throw CropError.exportFailed(session.error)
        }
        return outputURL
    }

    // MARK: - 第二步：直通重封装，补 still-image-time 定时轨道

    private static func addStillImageTimeTrack(
        sourceURL: URL,
        identifier: String,
        stillTime: Double
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw CropError.noVideoTrack
        }
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        guard let formatDescription = formatDescriptions.first else {
            throw CropError.noFormatDescription
        }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard reader.canAdd(readerOutput) else {
            throw CropError.cannotAddInput
        }
        reader.add(readerOutput)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        guard writer.canAdd(videoInput) else {
            throw CropError.cannotAddInput
        }
        writer.add(videoInput)

        guard let (metadataInput, metadataAdaptor) = LivePhotoMetadata.makeStillImageTimeTrack() else {
            throw CropError.metadataTrackFailed
        }
        guard writer.canAdd(metadataInput) else {
            throw CropError.cannotAddInput
        }
        writer.add(metadataInput)

        writer.metadata = [LivePhotoMetadata.contentIdentifierItem(identifier)]

        guard reader.startReading() else {
            throw CropError.readFailed(reader.error)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        guard writer.status != .failed else {
            throw CropError.writeFailed(writer.error)
        }

        // 写 still-image-time 样本（时间戳就是静态图时刻）
        _ = metadataAdaptor.append(LivePhotoMetadata.stillImageTimeGroup(at: stillTime))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.wallpaperstudio.video.passthrough")
            var didFinish = false
            func finish(_ error: Error?) {
                guard !didFinish else { return }
                didFinish = true
                if let error = error {
                    writer.cancelWriting()
                    continuation.resume(throwing: error)
                    return
                }
                videoInput.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: CropError.writeFailed(writer.error))
                    }
                }
            }
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        if reader.status == .failed {
                            finish(CropError.readFailed(reader.error))
                        } else {
                            finish(nil)
                        }
                        return
                    }
                    if !videoInput.append(sampleBuffer) {
                        finish(CropError.appendFailed(writer.error))
                        return
                    }
                }
            }
        }
        return outputURL
    }
}
