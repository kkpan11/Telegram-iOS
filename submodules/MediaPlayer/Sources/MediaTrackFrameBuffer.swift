import Foundation
import SwiftSignalKit
import CoreMedia

public enum MediaTrackFrameBufferStatus {
    case buffering(progress: Double)
    case full(until: Double)
    case finished(at: Double)
}

public enum MediaTrackFrameResult {
    case noFrames
    case skipFrame
    case restoreState(frames: [MediaTrackFrame], atTimestamp: CMTime, soft: Bool)
    case frame(MediaTrackFrame)
    case finished
}

private let traceEvents: Bool = {
    #if DEBUG && false
    return true
    #else
    return false
    #endif
}()

public final class MediaTrackFrameBuffer {
    private let stallDuration: Double
    private let lowWaterDuration: Double
    private let highWaterDuration: Double
    
    private let frameSource: MediaFrameSource
    private let decoder: MediaTrackFrameDecoder
    private let type: MediaTrackFrameType
    public let startTime: CMTime
    public let duration: CMTime
    public let rotationAngle: Double
    public let aspect: Double
    
    public var statusUpdated: () -> Void = { }
    
    private var frameSourceSinkIndex: Int?
    
    private(set) var frames: [MediaTrackDecodableFrame] = []
    private var maxFrameTime: Double?
    private var endOfStream = false
    private var bufferedUntilTime: CMTime?
    private var isWaitingForLowWaterDuration: Bool = false
    
    init(frameSource: MediaFrameSource, decoder: MediaTrackFrameDecoder, type: MediaTrackFrameType, startTime: CMTime, duration: CMTime, rotationAngle: Double, aspect: Double, stallDuration: Double = 1.0, lowWaterDuration: Double = 2.0, highWaterDuration: Double = 3.0) {
        self.frameSource = frameSource
        self.type = type
        self.decoder = decoder
        self.startTime = startTime
        self.duration = duration
        self.rotationAngle = rotationAngle
        self.aspect = aspect
        self.stallDuration = stallDuration
        self.lowWaterDuration = lowWaterDuration
        self.highWaterDuration = highWaterDuration
        
        self.frameSourceSinkIndex = self.frameSource.addEventSink { [weak self] event in
            if let strongSelf = self {
                switch event {
                    case let .frames(frames):
                        var filteredFrames: [MediaTrackDecodableFrame] = []
                        for frame in frames {
                            if frame.type == type {
                                filteredFrames.append(frame)
                            }
                        }
                        if !filteredFrames.isEmpty {
                            strongSelf.addFrames(filteredFrames)
                        }
                    case .endOfStream:
                        strongSelf.endOfStreamReached()
                }
            }
        }
    }
    
    deinit {
        if let frameSourceSinkIndex = self.frameSourceSinkIndex {
            self.frameSource.removeEventSink(frameSourceSinkIndex)
        }
    }
    
    private func addFrames(_ frames: [MediaTrackDecodableFrame]) {
        self.frames.append(contentsOf: frames)
        var maxUntilTime: CMTime?
        for frame in frames {
            let frameEndTime = CMTimeAdd(frame.pts, frame.duration)
            if self.bufferedUntilTime == nil || CMTimeCompare(self.bufferedUntilTime!, frameEndTime) < 0 {
                self.bufferedUntilTime = frameEndTime
                maxUntilTime = frameEndTime
            }
        }
        
        if let maxUntilTime = maxUntilTime {
            if let maxFrameTime = self.maxFrameTime {
                if maxFrameTime < CMTimeGetSeconds(maxUntilTime) {
                    self.maxFrameTime = CMTimeGetSeconds(maxUntilTime)
                }
            } else {
                self.maxFrameTime = CMTimeGetSeconds(maxUntilTime)
            }
            if traceEvents {
                print("\(self.type) added \(frames.count) frames until \(CMTimeGetSeconds(maxUntilTime)), \(self.frames.count) total")
            }
        }
        
        self.statusUpdated()
    }
    
    private func endOfStreamReached() {
        self.endOfStream = true
        self.isWaitingForLowWaterDuration = false
        self.statusUpdated()
    }
    
    public func status(at timestamp: Double) -> MediaTrackFrameBufferStatus {
        var bufferedDuration = 0.0
        if let bufferedUntilTime = self.bufferedUntilTime {
            if CMTimeGetSeconds(self.duration) > 0.0 {
                if CMTimeCompare(bufferedUntilTime, self.duration) >= 0 || self.endOfStream {
                    return .finished(at: CMTimeGetSeconds(bufferedUntilTime))
                }
            } else if self.endOfStream {
                return .finished(at: CMTimeGetSeconds(bufferedUntilTime))
            }
            
            bufferedDuration = CMTimeGetSeconds(bufferedUntilTime) - timestamp
        } else if self.endOfStream {
            if let maxFrameTime = self.maxFrameTime {
                return .finished(at: maxFrameTime)
            } else {
                return .finished(at: CMTimeGetSeconds(self.duration))
            }
        }
        
        let minTimestamp = timestamp - 1.0
        for i in (0 ..< self.frames.count).reversed() {
            if CMTimeGetSeconds(self.frames[i].pts) < minTimestamp {
                self.frames.remove(at: i)
            }
        }
        
        if bufferedDuration < self.lowWaterDuration {
            if traceEvents {
                print("\(self.type) buffered duration: \(bufferedDuration), requesting until \(timestamp) + \(self.highWaterDuration - bufferedDuration)")
            }
            let delayIncrement = 0.3
            var generateUntil = timestamp + delayIncrement
            while generateUntil < timestamp + self.highWaterDuration {
                self.frameSource.generateFrames(until: min(timestamp + self.highWaterDuration, generateUntil), types: [self.type])
                generateUntil += delayIncrement
            }
            
            if bufferedDuration > self.stallDuration && !self.isWaitingForLowWaterDuration {
                if traceEvents {
                    print("\(self.type) buffered1 duration: \(bufferedDuration), wait until \(timestamp) + \(self.highWaterDuration - bufferedDuration)")
                }
                return .full(until: timestamp + self.highWaterDuration)
            } else {
                self.isWaitingForLowWaterDuration = true
                return .buffering(progress: max(0.0, bufferedDuration / self.lowWaterDuration))
            }
        } else {
            self.isWaitingForLowWaterDuration = false
            if traceEvents {
                print("\(self.type) buffered2 duration: \(bufferedDuration), wait until \(timestamp) + \(bufferedDuration - self.lowWaterDuration)")
            }
            return .full(until: timestamp + max(0.0, bufferedDuration - self.lowWaterDuration))
        }
    }
    
    public var hasFrames: Bool {
        return !self.frames.isEmpty
    }
    
    public func takeFrame() -> MediaTrackFrameResult {
        if let decodedFrame = self.decoder.takeQueuedFrame() {
            return .frame(decodedFrame)
        }
        
        if !self.frames.isEmpty {
            let frame = self.frames.removeFirst()
            if self.decoder.send(frame: frame) {
                if let decodedFrame = self.decoder.decode() {
                    return .frame(decodedFrame)
                } else {
                    return .skipFrame
                }
            } else {
                return .skipFrame
            }
        } else {
            if self.endOfStream, let decodedFrame = self.decoder.takeRemainingFrame() {
                return .frame(decodedFrame)
            } else {
                if self.endOfStream {
                    return .finished
                } else if let bufferedUntilTime = self.bufferedUntilTime {
                    if CMTimeCompare(bufferedUntilTime, self.duration) >= 0 {
                        return .finished
                    }
                }
            }
        }
        return .noFrames
    }
}
