//
//  AVAssetTrack.swift
//  SFmpeg
//
//  Created by Andy Zhang on 2026/2/21.
//
import CoreMedia
import CFFmpeg

public class AVAssetTrack {
    var stream: AVStream

    var index: Int {
        get {
            stream.index
        }
    }

    var mediaType: AVMediaType {
        stream.mediaType
    }

    var codec: AVCodec

    var codecContext: AVCodecContext?

    var isEnabled: Bool {
        get {
            self.stream.discard != .all
        }
        set {
            self.stream.discard = newValue ? .default : .all
        }
    }

    lazy var startTime: Int64 = {
        if self.stream.startTime == swift_AV_NOPTS_VALUE {
            return 0
        }
        return self.stream.startTime
    }()

    public init?(stream: AVStream) throws {
        self.stream = stream
        let codec = AVCodec.findDecoderById(stream.codecParameters.codecId)
        guard let codec else {
            throw AVError.decoderNotFound
        }
        self.codec = codec
    }

    public func openCodecContext() throws {
        self.codecContext = AVCodecContext(codec: self.codec)
        guard self.codecContext != nil else {
            throw AVError.noSystem
        }
        self.codecContext?.setParameters(stream.codecParameters)

        if stream.mediaType == .video {
            // use VideoToolbox codec
            let hwContext = try AVHWDeviceContext(deviceType: .videoToolbox)
            self.codecContext?.hwDeviceContext = hwContext
        }

        try self.codecContext!.openCodec()
        logger.info("Created track for stream#\(self.stream.index), type: \(self.stream.mediaType.description), codec: \(self.codecContext!.codec?.name ?? "unknown")")
        if stream.mediaType == .audio {
            logger.debug(
            """
            Audio parameter: nb_channel:\(self.stream.codecParameters.channelLayout.channelCount), \
            bitRate: \(self.stream.codecParameters.bitRate), \
            sampleRate: \(self.stream.codecParameters.sampleRate), \
            sampleFormat: \(self.stream.codecParameters.sampleFormat.name ?? "unknown"),
            bytes/sample: \(self.stream.codecParameters.sampleFormat.bytesPerSample), \
            isPlanar: \(self.stream.codecParameters.sampleFormat.isPlanar),
            """)
        }
    }

    /// Converts from stream's PTS/DTS to CMTime, based on current track's timebase.
    public func toCMTime(from: Int64) -> CMTime {
        var result = CMTime.invalid
        if from != CFFmpeg.swift_AV_NOPTS_VALUE {
            let normalizedPTS = from - startTime
            result = CMTimeMake(value: from * Int64(stream.timebase.num), timescale: stream.timebase.den)
        }
        return result
    }

    // MARK: - description
    public func description() -> String {
        var parts: [String] = []

        // Stream identifier
        let streamId = stream.id != 0 ? "#\(stream.id)" : ""
        parts.append("Stream[\(stream.index)]\(streamId)")

        // Media type
        parts.append("type: \(stream.mediaType)")

        // Duration in seconds if available
        let durationSeconds = stream.duration > 0 ?
        String(format: "%.2fs", Double(stream.duration) * stream.timebase.toDouble) :
        "unknown"
        parts.append("duration: \(durationSeconds)")

        // Start time in seconds if available
        if stream.startTime != 0 && stream.startTime != Int64.min {
            let startTimeSeconds = String(format: "%.2fs", Double(stream.startTime) * stream.timebase.toDouble)
            parts.append("start: \(startTimeSeconds)")
        }

        // Frame rate (prefer average framerate for more accurate value)
        let fps = stream.averageFramerate.num > 0 && stream.averageFramerate.den > 0 ?
        stream.averageFramerate.toDouble :
        (stream.realFramerate.num > 0 && stream.realFramerate.den > 0 ? stream.realFramerate.toDouble : 0)

        if fps > 0 {
            parts.append(String(format: "fps: %.2f", fps))
        }

        // Number of frames if available
        if stream.frameCount > 0 {
            parts.append("frames: \(stream.frameCount)")
        }

        // Time base
        parts.append("timebase: \(stream.timebase.num)/\(stream.timebase.den)")

        // Sample aspect ratio (for video, show if not 1:1)
        let sar = stream.sampleAspectRatio.toDouble
        if stream.sampleAspectRatio.num > 0 && stream.sampleAspectRatio.den > 0 && sar != 1.0 {
            parts.append(String(format: "sar: %.2f", sar))
        }

        return parts.joined(separator: ", ")
    }
}
