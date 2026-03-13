# SFmpeg

A Swift wrapper for the FFmpeg API, adapted for **Swift 6 strict concurrency checking** with high-level abstractions for playing media files.

> **Educational Purpose**: This project is primarily intended for learning and education. It provides a clear, Swift-idiomatic way to understand and work with FFmpeg's media processing capabilities.

## Features

- **Swift 6 Ready**: Fully adapted to Swift 6 strict concurrency checking for safe, concurrent code
- **High-Level Abstractions**: Easy-to-use APIs like `SFPlayerItem` for playing media files without dealing with low-level FFmpeg details
- **Low-Level Access**: Full access to FFmpeg's C API when you need fine-grained control

> Note: SFmpeg is still in development, and the API is not guaranteed to be stable. It's subject to change without warning.

## Installation

FFmpeg is already included in this repository as an XCFramework (downloaded from [avbuild](https://github.com/wang-bin/avbuild)), so no separate FFmpeg installation is required.

### Swift Package Manager

SFmpeg uses [SwiftPM](https://swift.org/package-manager/) as its build tool. To depend on SFmpeg in your project, add a `dependencies` clause to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sunlubo/SwiftFFmpeg.git", from: "1.0.0")
]
```

## Documentation

- [API documentation](https://sunlubo.github.io/SwiftFFmpeg)

## Quick Start: Playing Media Files

The high-level `SFPlayerItem` abstraction makes it easy to work with media files:

```swift
import SFmpeg

// Create a player item from a media file
let playerItem = try SFPlayerItem(url: "path/to/media.mp4")

// Access media information
print("Duration: \(playerItem.duration) seconds")
print("Video tracks: \(playerItem.videoTracks.count)")
print("Audio tracks: \(playerItem.audioTracks.count)")

// Decode frames for playback
while let frame = try playerItem.decodeNextFrame() {
    // Process or display the frame
}
```

## Low-Level API Usage

For more control, you can use the low-level FFmpeg wrappers directly:

```swift
import Foundation
import SwiftFFmpeg

if CommandLine.argc < 2 {
    print("Usage: \(CommandLine.arguments[0]) <input file>")
    exit(1)
}
let input = CommandLine.arguments[1]

let fmtCtx = try AVFormatContext(url: input)
try fmtCtx.findStreamInfo()

fmtCtx.dumpFormat(isOutput: false)

guard let stream = fmtCtx.videoStream else {
    fatalError("No video stream.")
}
guard let codec = AVCodec.findDecoderById(stream.codecParameters.codecId) else {
    fatalError("Codec not found.")
}
let codecCtx = AVCodecContext(codec: codec)
codecCtx.setParameters(stream.codecParameters)
try codecCtx.openCodec()

let pkt = AVPacket()
let frame = AVFrame()

while let _ = try? fmtCtx.readFrame(into: pkt) {
    defer { pkt.unref() }

    if pkt.streamIndex != stream.index {
        continue
    }

    try codecCtx.sendPacket(pkt)

    while true {
        do {
            try codecCtx.receiveFrame(frame)
        } catch let err as AVError where err == .tryAgain || err == .eof {
            break
        }

        let str = String(
            format: "Frame %3d (type=%@, size=%5d bytes) pts %4lld key_frame %d",
            codecCtx.frameNumber,
            frame.pictureType.description,
            frame.pktSize,
            frame.pts,
            frame.isKeyFrame
        )
        print(str)

        frame.unref()
    }
}

print("Done.")
```