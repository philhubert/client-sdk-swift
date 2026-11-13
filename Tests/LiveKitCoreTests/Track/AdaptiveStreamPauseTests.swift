/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import CoreVideo
import Foundation
@testable import LiveKit
import LiveKitWebRTC
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// DokeTime fork: adaptiveStream pauses a video by asking the server to stop sending it, and
/// leaves the receive stream alone.
///
/// `LKRTCVideoTrack.shouldReceive = false` does more than stop decoding: libwebrtc tears the
/// receive stream down and builds a new one (`StopReceiveStream` calls `RecreateReceiveStream`).
/// On this WebRTC (M150, which demuxes on the network thread) a packet in flight across that
/// teardown reaches the handler for packets nobody owns, which fails to make a default stream for
/// an SSRC that already has one and then clears that SSRC's sink. From then on the video arrives
/// and decodes but no frame reaches any renderer, until it is subscribed again
/// (webrtc-sdk/webrtc#330). The server is still sending when the timer pauses a video, so every
/// pause was a chance of it.
@Suite(.serialized, .tags(.media, .e2e), TestLimits.e2e)
struct AdaptiveStreamPauseTests {
    /// Counts frames and never asks for video, so it changes nothing adaptiveStream decides.
    private final class FrameCounter: VideoRenderer, @unchecked Sendable {
        private let frames = StateSync(0)

        nonisolated var isAdaptiveStreamEnabled: Bool { false }
        nonisolated var adaptiveStreamSize: CGSize { .zero }

        func render(frame _: VideoFrame) {
            frames.mutate { $0 += 1 }
        }

        var count: Int { frames.copy() }
    }

    /// Asks for video, or not: a view that is on screen, or hidden.
    private final class View: VideoRenderer, @unchecked Sendable {
        private let isOnScreen = StateSync(true)

        nonisolated var isAdaptiveStreamEnabled: Bool { isOnScreen.copy() }
        nonisolated var adaptiveStreamSize: CGSize { CGSize(width: 1280, height: 720) }

        func set(onScreen: Bool) {
            isOnScreen.mutate { $0 = onScreen }
        }
    }

    /// 720p frames that differ from one to the next, about 30 a second, with no camera. Stops
    /// when the returned handle is dropped.
    private static func startCapture(into capturer: BufferCapturer) -> AnyTaskCancellable {
        Task.detached {
            let width = 1280, height = 720
            var pool: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            guard let pool else { return }
            var frame = 0
            while !Task.isCancelled {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                if let buffer {
                    CVPixelBufferLockBaseAddress(buffer, [])
                    if let base = CVPixelBufferGetBaseAddress(buffer) {
                        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                        memset(base, Int32(frame % 200) + 20, rowBytes * height)
                        let bandRows = 32
                        arc4random_buf(base + ((frame * 7) % (height - bandRows)) * rowBytes, bandRows * rowBytes)
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    capturer.capture(buffer)
                }
                frame += 1
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }.cancellable()
    }

    /// The video's inbound stream as the SDK last sampled it (about once a second).
    private static func inbound(_ track: RemoteVideoTrack) -> InboundRtpStreamStatistics? {
        let streams = track.statistics?.inboundRtpStream ?? []
        return streams.first { $0.kind == "video" } ?? streams.first
    }

    private static func framesDecoded(_ track: RemoteVideoTrack) -> UInt {
        inbound(track)?.framesDecoded ?? 0
    }

    private static func shouldReceive(_ track: RemoteVideoTrack) async -> Bool? {
        let mediaTrack = track.mediaTrack
        return await RTC.run { (mediaTrack.raw as? LKRTCVideoTrack)?.shouldReceive }
    }

    /// Waits for two samples in a row, taken at different times, that count the same packets:
    /// nothing arrived between them. A stream that never counted a packet doesn't qualify, so a
    /// rebuilt one, which starts over at zero, can't pass for a quiet one.
    private static func waitUntilNothingArrives(on track: RemoteVideoTrack) async throws {
        let previous = StateSync<(timestamp: Double, packets: UInt64)?>(nil)
        try await poll(timeout: 15, interval: 0.1, for: "the paused video to stop arriving") {
            guard let stream = inbound(track), let packets = stream.packetsReceived else { return false }
            return previous.mutate { last in
                guard let sample = last, sample.timestamp != stream.timestamp else {
                    if last == nil { last = (stream.timestamp, packets) }
                    return false
                }
                last = (stream.timestamp, packets)
                return packets > 0 && packets == sample.packets
            }
        }
    }

    /// A publisher sending synthetic H.264 video and a subscriber with adaptiveStream on, in one
    /// room, end-to-end encrypted like the app's. Runs `body` once the subscriber holds the
    /// video, and disconnects both on every path: a Room keeps itself alive through its transports.
    private static func withSubscribedVideo(
        _ body: (RemoteTrackPublication, RemoteVideoTrack) async throws -> Void
    ) async throws {
        let roomName = "adaptive-pause-\(UUID().uuidString.prefix(8))"
        let key = UUID().uuidString
        let url = TestEnvironment.liveKitServerUrl()
        try await TestEnvironment.waitForServer(url)

        func room(adaptiveStream: Bool) -> Room {
            Room(roomOptions: RoomOptions(
                adaptiveStream: adaptiveStream,
                dynacast: true,
                encryptionOptions: EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: key))
            ))
        }
        let publisher = room(adaptiveStream: false)
        let subscriber = room(adaptiveStream: true)

        do {
            try await publisher.connect(url: url, token: TestEnvironment.liveKitServerToken(
                for: roomName, identity: "publisher", canPublish: true
            ))
            try await subscriber.connect(url: url, token: TestEnvironment.liveKitServerToken(
                for: roomName, identity: "subscriber"
            ))

            let bufferTrack = await LocalVideoTrack.createBufferTrack(
                name: Track.cameraName,
                source: .camera,
                options: BufferCaptureOptions(dimensions: .h720_169)
            )
            let capturer = try #require(bufferTrack.capturer as? BufferCapturer)
            // A frame must exist before publishing, or the publish can't resolve its dimensions.
            let capture = startCapture(into: capturer)
            defer { capture.cancel() }
            try await Task.sleep(nanoseconds: 500_000_000)
            try await publisher.localParticipant.publish(videoTrack: bufferTrack, options: VideoPublishOptions(
                simulcast: true,
                preferredCodec: .h264
            ))

            @Sendable func subscribedVideo() -> (RemoteTrackPublication, RemoteVideoTrack)? {
                guard let publication = subscriber.remoteParticipants.values.first?.videoTracks.first as? RemoteTrackPublication,
                      let track = publication.track as? RemoteVideoTrack else { return nil }
                return (publication, track)
            }
            try await poll(timeout: 30, interval: 0.1, for: "the subscriber to hold the video") { subscribedVideo() != nil }
            let (publication, track) = try #require(subscribedVideo())
            await track.set(reportStatistics: true)
            try await body(publication, track)
        } catch {
            await publisher.disconnect()
            await subscriber.disconnect()
            throw error
        }
        await publisher.disconnect()
        await subscriber.disconnect()
    }

    @Test func pausingKeepsTheReceiveStream() async throws {
        try await Self.withSubscribedVideo { publication, track in
            let counter = FrameCounter()
            let view = View()
            track.add(videoRenderer: counter)
            track.add(videoRenderer: view)

            // Flowing, long enough that the stream's counters are well off zero.
            try await poll(timeout: 30, interval: 0.1, for: "the video to flow") {
                counter.count > 240 && Self.framesDecoded(track) > 240
            }
            let decodedBeforePause = Self.framesDecoded(track)

            // Nothing shows it any more: adaptiveStream pauses it.
            view.set(onScreen: false)
            try await poll(timeout: 10, interval: 0.05, for: "adaptiveStream to pause the video") { !publication.isEnabled }
            #expect(await Self.shouldReceive(track) == true,
                    "pausing set shouldReceive = false, which tears the receive stream down")
            // The pause itself is the server's: with the receive stream still up, what saves the
            // decoding is that nothing arrives.
            try await Self.waitUntilNothingArrives(on: track)

            // Shown again: it must render again.
            let renderedWhilePaused = counter.count
            view.set(onScreen: true)
            try await poll(timeout: 15, interval: 0.05, for: "the video to render again after the pause") {
                counter.count > renderedWhilePaused + 30
            }

            // The same receive stream carried it: a rebuilt one counts from zero again, and
            // can't have caught up this soon.
            #expect(Self.framesDecoded(track) >= decodedBeforePause,
                    "the receive stream's counters started over: it was rebuilt across the pause")
        }
    }
}
