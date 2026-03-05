//
//  AVAssetReader.swift
//  SFmpeg
//
//  Created by Andy Zhang on 2026/2/21.
//

import Foundation
import os.log

enum Status {
    case stopped
    case reading
    case seeking
    case eof
}

public class AVAssetReader {
    private let logger = Logger(subsystem: "fun.sfmpeg", category: "AVAssetReader")
    var asset: AVAsset

    private var packetBuffers: [Int:[AVPacket?]] = [:]

    private var readingTask: Task<Void, Never>?

    private var outputs: [Int:AVAssetReaderTrackOutput] = [:]

    public init(asset: AVAsset) {
        self.asset = asset
    }

    var status: Status = .stopped

    var readLock = NSLock()

    deinit {
        status = .stopped
    }

    private func seek(stream index: Int, to timestamp: Int64 = 0) {
        do {
            packetBuffers[index]!.removeAll()
            outputs[index]!.flush()
            try asset.formatContext.seekFrame(to: timestamp, streamIndex: index, flags: .backward)
        } catch let error {
            logger.error("Seek error: \(error)")
            if let e = error as? AVError {
                logger.error("Seek error: \(e.message)")
            }
        }
    }

    func seek(to timestamp: Int64 = 0) {
        readLock.lock()
        defer { readLock.unlock() }
        for idx in outputs.keys {
            seek(stream: idx, to: timestamp)
        }
    }

    public func add(_ output: AVAssetReaderTrackOutput) {
        do {
            output.track.isEnabled = true
            try output.track.openCodecContext()
            outputs[output.track.index] = output
            packetBuffers[output.track.index] = []
                // TODO: seek to nearest PTS to the first buffered packet
                // now just seek to 0.
                // This should be necessary when changing audio tracks mid-playback.
            seek(stream: output.track.index)
        } catch {
            logger.error("Failed to add output for stream#\(output.track.index): \(error)")
        }
    }

    public func startReading() {
        guard status == .stopped else { return }
        // set other stream to discard_all
        for strm in self.asset.streams {
            if outputs[strm.index] == nil {
                // output not enabled
                strm.discard = .all
            }
        }
        status = .reading
        for (_, output) in self.outputs {
            output.status = .reading
        }
        DispatchQueue.global().async { [weak self] in
            do {
                try self?.readingLoop()
            } catch {
                self?.logger.error("Unhandled error in reading loop: \(error)")
            }

            // set output's status to .eof
            for (_, output) in self?.outputs ?? [:] {
                output.status = .eof
            }
            self?.logger.notice("========== END OF READING LOOP =========")
            self?.logStatus()
        }
    }

    public func stopReading() {
        status = .stopped
        for idx in outputs.keys {
            outputs[idx]!.status = .eof
        }
    }

    public func flush() {
        for idx in outputs.keys {
            outputs[idx]!.flush()
            packetBuffers[idx]!.removeAll()
        }
    }

    private func logStatus() {
        logger.debug("------------- reader status ---------------")

        for (idx, output) in outputs {
            logger.debug("output#\(idx)[\(self.outputs[idx]?.mediaType.description ?? "unknown")]: in-flight frame: \(self.outputs[idx]?.frameBuffer.count ?? -1)")
            logger.debug("packetBuffer#\(idx): \(self.packetBuffers[idx]?.count ?? -1)")
        }
    }

    private func readingLoop() throws {
        var isEOF = false
        while !(self.status == .stopped || Thread.current.isCancelled) {
            try readLock.withLock {

                if status == .seeking {
                    Thread.sleep(forTimeInterval: 0.01)
                    return
                }
                if isEOF {
                    var bufferedPacketsCount = 0
                    for idx in packetBuffers.keys {
                        bufferedPacketsCount += packetBuffers[idx]!.count
                    }
                    if bufferedPacketsCount == 0 {
                            // eof and all buffered packets sent
                        self.status = .eof
                        return
                    }
                }
                var readiedOutput: [Int] = []
                for idx in outputs.keys {
                    if outputs[idx]!.isReadyForMoreData {
                        readiedOutput.append(idx)
                    }
                }
                if readiedOutput.isEmpty {
                        // no output is ready, sleep for a while and hop to next round
                    Thread.sleep(forTimeInterval: 0.01)
                    return
                }
                if !isEOF {
                        // receive new packet
                    do {
                        let pkt = AVPacket()
                        try asset.formatContext.readFrame(into: pkt)
                        if outputs.keys.contains(pkt.streamIndex) {
                            packetBuffers[pkt.streamIndex]!.append(pkt)
                            // logger.debug("[stream#\(pkt.streamIndex)] Enqueued packet DTS: \(pkt.dts), size: \(pkt.size)")
                            // logger.debug("Current buffer status:")
                            // logStatus()
                        } else {
                            pkt.unref()
                        }
                    } catch let error as AVError {
                        if error == .tryAgain {
                            return
                        }
                        if error == .eof {
                            logger.notice("======== EOF RECEIVED =========")
                            logStatus()
                            for idx in packetBuffers.keys {
                                    // append a nil packet to flush codec context
                                packetBuffers[idx]!.append(nil)
                            }
                            isEOF = true
                            return
                        }
                        logger.error("Read packet error: \(error.message)")
                        throw error
                    }
                }
                    // check if there's any buffered packet to be sent to output
                for idx in readiedOutput {
                    if packetBuffers[idx]!.isEmpty {
                        return
                    }
                        // send packet to output for decoding
                    do {
                        let packet = packetBuffers[idx]!.removeFirst()
                        try outputs[idx]!.receive(packet)
                        packet?.unref()
                    } catch let error as AVError {
                        if error == .tryAgain {
                            return
                        }
                        throw error
                    }
                }
            }

        }
    }

}
