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

import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// DokeTime fork: the adaptiveStream timer reads a track's renderer table on main while
/// `add`/`remove(videoRenderer:)` mutate it from other threads, so the read takes the lock.
@Suite(.tags(.concurrency))
struct AttachedVideoRenderersTests {
    private final class Renderer: NSObject, VideoRenderer, @unchecked Sendable {
        var isAdaptiveStreamEnabled: Bool { true }
        var adaptiveStreamSize: CGSize { .zero }
    }

    private static func makeTrack() -> RemoteVideoTrack {
        RemoteVideoTrack(name: "video",
                         source: .camera,
                         track: RTCMediaTrack(RTC.createVideoTrack(source: RTC.createVideoSource(forScreenShare: false))),
                         reportStatistics: false)
    }

    private static func attach(_ renderer: Renderer, to track: Track) {
        track._state.mutate { $0.videoRendererAdapters.setObject(VideoRendererAdapter(renderer: renderer), forKey: renderer) }
    }

    @Test func listsTheAttachedRenderers() {
        let track = Self.makeTrack()
        let renderer = Renderer()
        Self.attach(renderer, to: track)

        let renderers = track.attachedVideoRenderers
        #expect(renderers.count == 1)
        #expect(renderers.first === renderer)
    }

    /// Another thread attaches and detaches, as the app's attach queue and the SDK's binder do,
    /// while this one reads like the timer. Enumerating unlocked races the mutation.
    @Test func readingWhileAnotherThreadAttachesIsSafe() {
        let track = Self.makeTrack()
        let kept = Renderer()
        Self.attach(kept, to: track)

        let done = StateSync(false)
        let writer = Thread {
            for _ in 0 ..< 50000 {
                let renderer = Renderer()
                Self.attach(renderer, to: track)
                track._state.mutate { $0.videoRendererAdapters.removeObject(forKey: renderer) }
            }
            done.mutate { $0 = true }
        }
        writer.start()

        var keptMissing = 0
        while !done.read({ $0 }) {
            if !track.attachedVideoRenderers.contains(where: { $0 === kept }) { keptMissing += 1 }
        }
        #expect(keptMissing == 0)
    }
}
