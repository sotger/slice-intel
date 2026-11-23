//
//  Exporter.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/8/26.
//

import AVFoundation
import CoreImage

public enum Exporter {
    public enum Failure: LocalizedError {
        case failed(String)
        public var errorDescription: String? { if case let .failed(m) = self { m } else { nil } }
    }

    public static func export(project: Project, bundle: ProjectBundle, cursor: CursorTrack, captions: [Caption] = [], to url: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let settings = project.export
        if settings.format == .gif {
            return try await exportGIF(project: project, bundle: bundle, cursor: cursor, captions: captions, to: url,
                                       progress: progress)
        }
        let size = project.renderSize
        let built = try await build(project: project, bundle: bundle, cursor: cursor, captions: captions, size: size,
                                    fps: settings.fps)
        let total = max(project.duration, 0.001)

        let reader = try AVAssetReader(asset: built.composition)
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await built.composition.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            out.audioMix = built.audioMix
            // The limiter works on the samples in place, so they must be the output's own copy.
            out.alwaysCopiesSampleData = true
            reader.add(out)
            audioOut = out
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitRate(for: size, duration: project.duration),
            AVVideoExpectedSourceFrameRateKey: settings.fps,
        ]
        if settings.hevc {
            // HEVC only takes the keyframe interval in frames; a duration raises from AVAssetWriterInput.
            compression[AVVideoMaxKeyFrameIntervalKey] = max(settings.fps * 2, 1)
        } else {
            compression[AVVideoMaxKeyFrameIntervalDurationKey] = 2
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: settings.audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading() else { throw reader.error ?? Failure.failed("Couldn't read the project's media.") }
        guard writer.startWriting() else { throw writer.error ?? Failure.failed("Couldn't write the movie file.") }
        writer.startSession(atSourceTime: .zero)

        let cancel = ReaderBox(reader: reader)
        await withTaskCancellationHandler {
            async let video: Void = pump(videoOut, into: videoIn, label: "export.video") { t in progress(min(t / total, 0.999)) }
            if let audioOut, let audioIn {
                var limiter = PeakLimiter(sampleRate: 48000)
                await pump(audioOut, into: audioIn, label: "export.audio", process: { limiter.limit($0) }) { _ in }
            }
            await video
        } onCancel: {
            cancel.reader.cancelReading()
        }
        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? Failure.failed("Reading the project failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.failed("Writing the movie failed.") }
        progress(1)
    }

    static func build(project: Project, bundle: ProjectBundle, cursor: CursorTrack, captions: [Caption], size: CGSize,
                      fps: Int) async throws -> CompositionBuilder.Result {
        let state = RenderState(project: project, cursor: cursor)
        state.update(options: FrameRenderer.Options(accurateSegmentation: true))
        state.update(backgroundImage: bundle.backgroundImage(for: project))
        state.update(captions: captions)
        state.add(stills: await TransitionStills.load(project.transitionStills, project: project, bundle: bundle))
        return try await CompositionBuilder.build(project: project, bundle: bundle, state: state, renderSize: size, fps: fps)
    }

    // MARK: - Audio stems

    public struct Stem {
        public var name: String
        public var tracks: [CMPersistentTrackID]
    }

    /// One stem per source: the microphone, the apps' sound, the music, and each imported track.
    public static func stems(project: Project, layout: CompositionBuilder.AudioLayout) -> [Stem] {
        var out: [Stem] = []
        if let mic = layout.mic { out.append(Stem(name: "Mic", tracks: [mic])) }
        if let screen = layout.screen { out.append(Stem(name: "App", tracks: [screen])) }
        if !layout.music.isEmpty { out.append(Stem(name: "Music", tracks: layout.music.map(\.trackID))) }
        for imported in layout.imported {
            let name = project.audioTracks.first { $0.id == imported.id }?.name ?? "Track"
            out.append(Stem(name: name, tracks: [imported.trackID]))
        }
        return out
    }

    /// Writes every source as its own PCM WAV, aligned to the edited timeline and with the project's volumes,
    /// fades and ducking applied — for mixing the podcast in another editor.
    public static func exportStems(project: Project, bundle: ProjectBundle, cursor: CursorTrack, to folder: URL,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        let built = try await build(project: project, bundle: bundle, cursor: cursor, captions: [], size: project.renderSize,
                                    fps: project.export.fps)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw Failure.failed("This project has no audio to export.") }
        let stems = stems(project: project, layout: built.audioLayout)
        guard !stems.isEmpty else { throw Failure.failed("This project has no audio to export.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (i, stem) in stems.enumerated() {
            let url = folder.appendingPathComponent("\(project.name) — \(stem.name).wav")
            try writeStem(url: url, composition: built.composition, tracks: audioTracks, target: Set(stem.tracks),
                          mix: built.audioMix)
            urls.append(url)
            progress(Double(i + 1) / Double(stems.count))
        }
        return urls
    }

    private static func writeStem(url: URL, composition: AVComposition, tracks: [AVAssetTrack],
                                  target: Set<CMPersistentTrackID>, mix: AVAudioMix?) throws {
        let reader = try AVAssetReader(asset: composition)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        let stemMix = AVMutableAudioMix()
        var params: [AVAudioMixInputParameters] = []
        for track in tracks {
            if target.contains(track.trackID) {
                if let existing = mix?.inputParameters.first(where: { $0.trackID == track.trackID }) {
                    params.append(existing)
                    continue
                }
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(1, at: .zero)
                params.append(p)
            } else {
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(0, at: .zero)
                params.append(p)
            }
        }
        stemMix.inputParameters = params
        output.audioMix = stemMix
        output.alwaysCopiesSampleData = true
        reader.add(output)
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.startReading() else { throw Failure.failed("Couldn't read the project's audio.") }
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = pcmBuffer(sample, format: file.processingFormat) { try file.write(from: buffer) }
        }
        if reader.status == .failed { throw Failure.failed(reader.error?.localizedDescription ?? "Reading the audio failed.") }
    }

    private static func pcmBuffer(_ sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return nil }
        var length = 0, total = 0
        var data: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &total,
                                          dataPointerOut: &data) == kCMBlockBufferNoErr, let data else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let count = Int(format.channelCount)
        data.withMemoryRebound(to: Float.self, capacity: frames * count) { source in
            for channel in 0 ..< count {
                for frame in 0 ..< frames { channels[channel][frame] = source[frame * count + channel] }
            }
        }
        return buffer
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                             process: ((CMSampleBuffer) -> Void)? = nil,
                             progress: @escaping @Sendable (Double) -> Void) async {
        let queue = DispatchQueue(label: label)
        let box = SendableBox(output: output, input: input, process: process)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            box.input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while box.input.isReadyForMoreMediaData {
                    guard let sample = box.output.copyNextSampleBuffer() else {
                        box.input.markAsFinished()
                        finished = true
                        done.resume()
                        return
                    }
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    box.process?(sample)
                    guard box.input.append(sample) else {
                        finished = true
                        done.resume()
                        return
                    }
                    if t.isFinite { progress(t) }
                }
            }
        }
    }

    struct ReaderBox: @unchecked Sendable {
        let reader: AVAssetReader
    }

    private struct SendableBox: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let process: ((CMSampleBuffer) -> Void)?
    }
}

extension PeakLimiter {
    mutating func limit(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var contiguous = 0, total = 0
        var data: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: &total,
                                          dataPointerOut: &data) == kCMBlockBufferNoErr,
              let data, contiguous == total else { return }
        let channels = 2
        data.withMemoryRebound(to: Float.self, capacity: total / 4) {
            process($0, frames: total / 4 / channels, channels: channels)
        }
    }
}
