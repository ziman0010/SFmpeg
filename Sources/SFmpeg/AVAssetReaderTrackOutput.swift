//
//  AVAssetReaderTrackOutput.swift
//  SFmpeg
//
//  Created by Andy Zhang on 2026/2/21.
//

import os.log
import CoreMedia
import CFFmpeg
import CoreAudio
import CoreImage

public typealias DynamicContent = CMSampleBuffer.DynamicContent

public class AVAssetReaderTrackOutput {
    private var logger: Logger = Logger(subsystem: "fun.sfmpeg", category: "AVAssetReaderTrackOutput")

    var mediaType: AVMediaType

    var track: AVAssetTrack

    var codecpar: AVCodecParameters {
        get {
            track.stream.codecParameters
        }
    }

    let maxFramesInFlight: Int = 2

    var status: Status = .stopped

    var frameBuffer: [CMReadySampleBuffer<DynamicContent>] = []

    var isReadyForMoreData: Bool {
        get {
            frameBuffer.count < maxFramesInFlight
        }
    }

    public var hasSufficientMediaDataForReliablePlaybackStart: Bool {
        get {
            frameBuffer.count >= maxFramesInFlight
        }
    }

    /// for audio track
    var swrContext: SwrContext?
    var targetAudioSampleFormat: AVSampleFormat = .float
    var stagedAudioSampleBuffer: CMReadOnlyDataBlockBuffer!
    var stagedAudioSampleCount: Int = 0
    var stagedPTS: CMTime!
    var maxAudioSampleInStage: Int = 0

    /// for video track
    var swsContext: SwsContext?

    lazy var audioFormatDescription: CMAudioFormatDescription? = {
            // create asbd
        let asbd = createAudioStreamBasicDescription(
            sampleRate: Float64(codecpar.sampleRate),
            channelCount: UInt32(codecpar.channelLayout.channelCount),
            sampleFormat: targetAudioSampleFormat
        )
        return try? CMAudioFormatDescription(audioStreamBasicDescription: asbd)
    }()

    var bufLock = NSLock()

    public init?(track: AVAssetTrack) {
        self.track = track
        mediaType = track.stream.mediaType

        switch mediaType {
        case .video:
            break
//            do {
//                swsContext = try SwsContext(
//                    srcWidth: codecpar.width,
//                    srcHeight: codecpar.height,
//                    srcPixelFormat: codecpar.pixelFormat,
//                    dstWidth: codecpar.width,
//                    dstHeight: codecpar.height,
//                    dstPixelFormat: .NV12,
//                    flags: .fastBilinear
//                )
//            } catch {
//                logger.error("Failed to create swscontext: \(error)")
//                return nil
//            }
        case .audio:
            do {
                swrContext = try SwrContext(
                    inputChannelLayout: codecpar.channelLayout,
                    inputSampleFormat: codecpar.sampleFormat,
                    inputSampleRate: codecpar.sampleRate,
                    outputChannelLayout: codecpar.channelLayout,
                    outputSampleFormat: targetAudioSampleFormat,
                    outputSampleRate: codecpar.sampleRate
                )
                try swrContext?.initialize()
                maxAudioSampleInStage = codecpar.sampleRate / 2
            } catch {
                logger.error("Failed to create swrcontext: \(error)")
                return nil
            }
        default:
            break
        }
    }

    public func flush() {
        bufLock.lock()
        defer { bufLock.unlock() }
        frameBuffer.removeAll()
        if mediaType == .audio {
            stagedPTS = nil
            stagedAudioSampleBuffer = nil
            stagedAudioSampleCount = 0
        }
        track.codecContext?.flush()
    }

    public func copyNextSampleBuffer() -> CMReadySampleBuffer<DynamicContent>? {
        while status != .eof {
            if let frm = safeDequeueFrame() {
                return frm
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // deal with the remaining frames when eof reached
        logger.debug("[stream#\(self.track.index)] Remaining frames after eof: \(self.frameBuffer.count)")
        if mediaType == .audio {
            logger.debug("[stream#\(self.track.index)] Staged audio samples: \(self.stagedAudioSampleCount)")
        }
        return safeDequeueFrame()
    }

    private func safeDequeueFrame() -> CMReadySampleBuffer<DynamicContent>? {
        bufLock.lock()
        defer { bufLock.unlock() }
        if frameBuffer.isEmpty {
            return nil
        }
        return frameBuffer.removeFirst()
    }

    private func safeEnqueueFrame(_ frame: CMReadySampleBuffer<DynamicContent>) {
        bufLock.lock()
        defer { bufLock.unlock() }
        frameBuffer.append(frame)
    }

    func receive(_ packet: AVPacket?) throws {
        if packet != nil {
            do {
                try track.codecContext?.sendPacket(packet)
            } catch let error as AVError {
                if error == .tryAgain {
                        // need to read all frames before sending this packet
                    try? receiveFrames()
                    try? track.codecContext?.sendPacket(packet)
                } else {
                    throw error
                }
            }
        } else {
            // send NULL to codecContext to flush it
            logger.notice("[stream#\(self.track.index)] Sending NULL to codecContext")
            try? track.codecContext?.sendPacket(nil)
        }
        do {
            try receiveFrames()
        } catch let error as AVError {
            // all frames received, ignore this error and break the loop
            if packet == nil && mediaType == .audio {
                // schedule last audio frame no matter how many samples accumulated
                logger.notice("Last packet received, scheduling audio frame immediately.")
                if let sampleBuffer = scheduleAudioFrame() {
                    safeEnqueueFrame(sampleBuffer)
                }
            }
            if error.code == AVError.tryAgain.code {
                return
            }
            if error.code == AVError.eof.code {
                if mediaType == .audio {
                    // schedule audio frame if possible
                    logger.notice("EOF reached, scheduling audio frame immediately.")
                    if let sampleBuffer = scheduleAudioFrame() {
                        safeEnqueueFrame(sampleBuffer)
                    }
                }
                // and set this output to .eof
                status = .eof
                return
            }
            logger.error("[stream#\(self.track.index)] Unexpected error when receiving packet: \(error)")
        }
    }

    private func receiveFrames() throws {
        var frame = AVFrame()
        while true {
            try track.codecContext?.receiveFrame(frame)
            if let sampleBuffer = try createSampleBuffer(from: frame) {
                safeEnqueueFrame(sampleBuffer)
                frame.unref()
            } else {
                logger.error("[stream#\(self.track.index)] Failed to create sample buffer from frame")
                break
            }
        }
    }

    func createSampleBuffer(from frame: AVFrame) throws -> CMReadySampleBuffer<DynamicContent>? {
        if mediaType == .video {
            return createVideoSampleBuffer(from: frame)
        }
        if mediaType == .audio {
            return try createAudioSampleBuffer(from: frame)
        }
        return nil
    }

    private func createVideoSampleBuffer(from frame: AVFrame) -> CMReadySampleBuffer<DynamicContent>? {
            // calculate PTS
        let presentationTime = track.toCMTime(from: frame.bestEffortTimestamp)
        let durationTime = track.toCMTime(from: frame.duration)

        guard let roPixelBuffer = getPixelBuffer(from: frame) else {
            logger.error("Failed to get pixel buffer from frame and fallback image")
            return nil
        }


        let sampleBuffer = CMReadySampleBuffer(
            pixelBuffer: roPixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: durationTime
        )
        sampleBuffer.formatDescription

        return CMReadySampleBuffer<DynamicContent>(sampleBuffer)
    }

    private func getPixelBuffer(from frame: AVFrame) -> CVReadOnlyPixelBuffer? {
        switch frame.pixelFormat {
        case .VIDEOTOOLBOX:
            nonisolated(unsafe) let inputPixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(frame.data[3]!).takeUnretainedValue()
            if inputPixelBuffer == nil {
                logger.warning("Failed to get pixel buffer from frame")
                return nil
            }
            return CVReadOnlyPixelBuffer(unsafeBuffer: inputPixelBuffer)

        default:
            logger.warning("Frame is not supported. format: \(frame.pixelFormat.name)")
            return nil
        }
    }

    private func createAudioSampleBuffer(from frame: AVFrame) throws -> CMReadySampleBuffer<DynamicContent>? {
        guard let audioFormatDescription else {
            logger.error("Failed to create audio format description")
            return nil
        }
        guard frame.sampleFormat != .none,
              frame.sampleRate > 0,
              frame.sampleCount > 0,
              frame.channelLayout.channelCount > 0 else {
            logger.error("Invalid audio frame. \(frame.sampleFormat.name ?? "unknown"), \(frame.sampleRate), \(frame.sampleCount), \(frame.channelLayout.channelCount)")
            return nil
        }

        var outSampleCount = 0
        var blockBuf = createCMBlockBuffer(for: frame, &outSampleCount)

        guard let blockBuf, outSampleCount > 0 else {
            logger.error("Failed to create block buffer for audio frame")
            return nil
        }

        if stagedPTS == nil {
                // calculate PTS
            stagedPTS = track.toCMTime(from: frame.bestEffortTimestamp)
                //            var durationTime = track.toCMTime(from: frame.duration)
        }

            // stage current audio frame
        stagedAudioSampleCount += outSampleCount
        if stagedAudioSampleBuffer == nil {
            stagedAudioSampleBuffer = blockBuf
        } else {
            stagedAudioSampleBuffer += blockBuf
        }
        if stagedAudioSampleCount < maxAudioSampleInStage {
            throw AVError.tryAgain
        }

        return scheduleAudioFrame()
    }

    private func scheduleAudioFrame() -> CMReadySampleBuffer<DynamicContent>? {
        guard let audioFormatDescription else {
            logger.error("Failed to create audio format description")
            return nil
        }
        // there's no staged audio sample
        if stagedPTS == nil { return nil }

        let sampleBuf = CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>(
            audioDataBuffer: stagedAudioSampleBuffer,
            formatDescription: audioFormatDescription,
            sampleCount: stagedAudioSampleCount,
            presentationTimeStamp: stagedPTS!
        )
        // reset staged sample
        stagedAudioSampleCount = 0
        stagedAudioSampleBuffer = nil
        stagedPTS = nil
        return CMReadySampleBuffer<DynamicContent>(sampleBuf)
    }

    private func createAudioStreamBasicDescription(
        sampleRate: Float64,
        channelCount: UInt32,
        sampleFormat: AVSampleFormat
    ) -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()

        asbd.mSampleRate = sampleRate
        asbd.mChannelsPerFrame = channelCount
        asbd.mFramesPerPacket = 1

        // Always use float packed format (converted via swrContext)
        asbd.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked
        asbd.mFormatID = kAudioFormatLinearPCM

        asbd.mBitsPerChannel = UInt32(targetAudioSampleFormat.bytesPerSample * 8)
        asbd.mBytesPerFrame = UInt32(targetAudioSampleFormat.bytesPerSample) * asbd.mChannelsPerFrame
        asbd.mBytesPerPacket = asbd.mBytesPerFrame

        return asbd
    }

    private func createCMBlockBuffer(for frame: AVFrame, _ outSampleCount: inout Int) -> CMReadOnlyDataBlockBuffer? {
        if let swrContext {
            do {
                let outMaxSampleCount = try swrContext.getOutSamples(Int64(frame.sampleCount))
                let (outBufSize, outLineSize) = try AVSamples.getBufferSize(
                    channelCount: frame.channelLayout.channelCount,
                    sampleCount: frame.sampleCount,
                    sampleFormat: targetAudioSampleFormat,
                    align: 1
                )
                var outBuf = UnsafeMutableRawPointer.allocate(byteCount: outBufSize, alignment: 2)
                defer { outBuf.deallocate() }
                var outBufPtr: UnsafeMutablePointer<UInt8>? = outBuf.assumingMemoryBound(to: UInt8.self)
                var frameData = frame.data.map { UnsafePointer<UInt8>($0) }
                outSampleCount = try swrContext.convert(
                    dst: &outBufPtr,
                    dstCount: outMaxSampleCount,
                    src: &frameData,
                    srcCount: frame.sampleCount
                )
                let abuf = AudioBuffer(
                    mNumberChannels: UInt32(frame.channelLayout.channelCount),
                    mDataByteSize: UInt32(outSampleCount * frame.channelLayout.channelCount * targetAudioSampleFormat.bytesPerSample),
                    mData: outBufPtr
                )
                var abuflist = AudioBufferList(mNumberBuffers: 1, mBuffers: abuf)
                return .init(CMMutableDataBlockBuffer(copying: &abuflist))
            } catch {
                logger.error("Unhandled error when swresample: \(error)")
            }
        } else {
            logger.error("Packed sample format not found!!")
        }

        return nil
    }
}

