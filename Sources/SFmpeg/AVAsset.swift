//
//  AVAsset.swift
//  SFmpeg
//
//  Created by Andy Zhang on 2026/2/20.
//

import Foundation
import CoreMedia
import os.log

public class AVAsset {
    var formatContext: AVFormatContext

    var streams: [AVStream] {
        get {
            formatContext.streams
        }
    }

    var tracks: [AVAssetTrack] = []

    public init?(url: URL) throws {
        do {
            if url.isFileURL {
                let path = url.path.removingPercentEncoding ?? url.path
                try formatContext = AVFormatContext(url: path)
            } else {
                try formatContext = AVFormatContext(url: url.absoluteString)
            }
            try formatContext.findStreamInfo()
        } catch let error {
            throw error
        }
    }

    public func loadTracks(withMediaType mediaType: AVMediaType) throws -> [AVAssetTrack] {
        if tracks.isEmpty {
            for stream in streams {
                do {
                    if let track = try AVAssetTrack(stream: stream) {
                        tracks.append(track)
                    }
                } catch let error as AVError {
                    logger.error("Failed to load track: \(error.message)")
                } catch {
                    logger.error("Unknown error in \(#function): \(error)")
                }
            }
        }
        return tracks.filter { $0.mediaType == mediaType }
    }
}

