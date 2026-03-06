import AVFoundation
import CoreMedia
import os.log

public typealias SampleBufferModifier = (CMReadySampleBuffer<DynamicContent>) -> CMReadySampleBuffer<DynamicContent>

func enqueueReadySampleBufferWithModifier(
    sampleBuffer: CMReadySampleBuffer<DynamicContent>,
    renderer: AVQueuedSampleBufferRendering,
    modifier: SampleBufferModifier?
) {
    if let modifier {
        let modifiedSampleBuffer = modifier(sampleBuffer)
        modifiedSampleBuffer.withUnsafeSampleBuffer() { sbuf in
            renderer.enqueue(sbuf)
        }
    } else {
        sampleBuffer.withUnsafeSampleBuffer() { sbuf in
            renderer.enqueue(sbuf)
        }
    }
}

@Observable
public class SFPlayerItem: @unchecked Sendable {
    private let logger = Logger(subsystem: "fun.sfmpeg", category: "SFPlayerItem")
    
    public let asset: AVAsset
    public private(set) var status: SFPlayerItemStatus = .unknown
    public private(set) var error: Error?
    
    public var duration: CMTime {
        let formatDuration = asset.formatContext.duration
        guard formatDuration > 0 else { return .zero }
        return CMTime(value: formatDuration, timescale: 1_000_000)
    }
    
    public var currentTime: CMTime {
        synchronizer.currentTime()
    }
    
    public var rate: Float {
        get { synchronizer.rate }
        set { synchronizer.setRate(newValue, time: currentTime) }
    }
    
    public let synchronizer = AVSampleBufferRenderSynchronizer()
    public let audioRenderer = AVSampleBufferAudioRenderer()
    
    public var videoRenderer: AVQueuedSampleBufferRendering?
    
    private var assetReader: AVAssetReader?
    private var audioOutput: AVAssetReaderTrackOutput?
    private var videoOutput: AVAssetReaderTrackOutput?

    public var sampleBufferModifier: SampleBufferModifier?

    private var audioFeedingTask: Task<Void, Never>?
    private var videoFeedingTask: Task<Void, Never>?
    
    private var isSeeking = false

    public init(asset: AVAsset, _ sampleBufferModifier: SampleBufferModifier? = nil) {
        self.asset = asset
        self.sampleBufferModifier = sampleBufferModifier
        synchronizer.addRenderer(audioRenderer)
    }
    
    public convenience init?(url: URL) {
        guard let asset = try? AVAsset(url: url) else { return nil }
        self.init(asset: asset)
    }
    
    public func setVideoRenderer(_ renderer: AVQueuedSampleBufferRendering) {
        if let existing = videoRenderer {
            synchronizer.removeRenderer(existing, at: currentTime)
        }
        videoRenderer = renderer
        synchronizer.addRenderer(renderer)
    }
    
    public func prepare() async throws {
        do {
            let audioTracks = try asset.loadTracks(withMediaType: .audio)
            let videoTracks = try asset.loadTracks(withMediaType: .video)
            
            let reader = AVAssetReader(asset: asset)
            
            if let audioTrack = audioTracks.first,
               let audioOut = AVAssetReaderTrackOutput(track: audioTrack) {
                reader.add(audioOut)
                audioOutput = audioOut
            }
            
            if let videoTrack = videoTracks.first,
               let videoOut = AVAssetReaderTrackOutput(track: videoTrack) {
                reader.add(videoOut)
                videoOutput = videoOut
            }
            
            assetReader = reader
            status = .readyToPlay
        } catch {
            self.error = error
            status = .failed
            throw error
        }
    }
    
    public func play() {
        guard status == .readyToPlay else { return }
        
        assetReader?.startReading()
        startFeeding()
        
        synchronizer.setRate(1.0, time: currentTime)
    }
    
    public func pause() {
        synchronizer.setRate(0.0, time: currentTime)
    }
    
    private func startFeeding() {
        startAudioFeeding()
        startVideoFeeding()
    }
    
    private func stopFeeding() {
        audioFeedingTask?.cancel()
        videoFeedingTask?.cancel()
        audioFeedingTask = nil
        videoFeedingTask = nil
    }
    
    private func startAudioFeeding() {
        guard let output = audioOutput else { return }
        let renderer = audioRenderer
        let logger = self.logger

        audioFeedingTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                if self?.isSeeking ?? true {
                    return
                }
                
                if renderer.isReadyForMoreMediaData {
                    if let readySampleBuffer = output.copyNextSampleBuffer() {
                        do {
                            enqueueReadySampleBufferWithModifier(
                                sampleBuffer: readySampleBuffer,
                                renderer: renderer,
                                modifier: self?.sampleBufferModifier
                            )
                        } catch {
                            logger.error("Failed to enqueue audio sample buffer: \(error)")
                        }
                    } else {
                        logger.debug("Audio output finished")
                        return
                    }
                } else {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }
    
    private func startVideoFeeding() {
        guard let output = videoOutput, let renderer = videoRenderer else { return }
        let logger = self.logger

        videoFeedingTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                if self?.isSeeking ?? true {
                    return
                }

                if renderer.isReadyForMoreMediaData {
                    if let readySampleBuffer = output.copyNextSampleBuffer() {
                        do {
                            enqueueReadySampleBufferWithModifier(
                                sampleBuffer: readySampleBuffer,
                                renderer: renderer,
                                modifier: self?.sampleBufferModifier
                            )
                        } catch {
                            logger.error("Failed to enqueue video sample buffer: \(error)")
                        }
                    } else {
                        logger.debug("Video output finished")
                        return
                    }
                } else {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }
    
    public func seek(to time: CMTime,
                     toleranceBefore: CMTime = .positiveInfinity,
                     toleranceAfter: CMTime = .positiveInfinity) async -> Bool {
        isSeeking = true
        defer { isSeeking = false }
        
        stopFeeding()
        
        synchronizer.setRate(0.0, time: currentTime)
        logger.debug("Start seeking to \(time.seconds)")

        guard let reader = assetReader else { return false }
        
        let seconds = time.seconds
        
        if let videoOutput {
            let tb = videoOutput.track.stream.timebase
            let timestamp = Int64(seconds * Double(tb.den) / Double(tb.num))
            reader.seek(to: timestamp)
        }

        audioRenderer.flush()
        videoRenderer?.flush()

        // Wait for the first video frame and get its PTS
        guard let audioOutput else {
            logger.critical("Audio output is nil")
            return false
        }
        guard let firstSampleBuffer = audioOutput.copyNextSampleBuffer() else {
            logger.error("Failed to get first video sample buffer after seek")
            return false
        }
        let audioPTS = firstSampleBuffer.presentationTimeStamp
        logger.debug("After seek: first audio frame PTS: \(audioPTS.seconds)")
            // Enqueue the first frame
        enqueueReadySampleBufferWithModifier(
            sampleBuffer: firstSampleBuffer,
            renderer: audioRenderer,
            modifier: self.sampleBufferModifier
        )
        synchronizer.setRate(0.0, time: audioPTS)
        if let firstVideoFrame = videoOutput?.copyNextSampleBuffer() {
            let videoPTS = firstVideoFrame.presentationTimeStamp
            logger.debug("After seek: first video frame PTS: \(videoPTS.seconds)")
            if let videoRenderer {
                enqueueReadySampleBufferWithModifier(
                    sampleBuffer: firstVideoFrame,
                    renderer: videoRenderer,
                    modifier: self.sampleBufferModifier
                )
            }
            if videoPTS > audioPTS {
                synchronizer.setRate(0.0, time: videoPTS)
            }
        }

            // 使用实际 PTS 设置 synchronizer 时间
        synchronizer.rate = 1.0

        isSeeking = false
        startFeeding()

        return true
    }
    
    public func addPeriodicTimeObserver(forInterval interval: CMTime,
                                         queue: DispatchQueue? = nil,
                                         using: @escaping (CMTime) -> Void) -> Any {
        synchronizer.addPeriodicTimeObserver(forInterval: interval, queue: queue, using: using)
    }
    
    public func addBoundaryTimeObserver(forTimes times: [NSValue],
                                         queue: DispatchQueue? = nil,
                                         using: @escaping () -> Void) -> Any {
        synchronizer.addBoundaryTimeObserver(forTimes: times, queue: queue, using: using)
    }
    
    public func removeTimeObserver(_ observer: Any) {
        synchronizer.removeTimeObserver(observer)
    }
    
    deinit {
        stopFeeding()
        assetReader?.stopReading()
        if let videoRenderer {
            synchronizer.removeRenderer(videoRenderer, at: .zero, completionHandler: nil)
        }
    }
}
