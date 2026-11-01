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

/// DokeTime fork: a quick reconnect's completion resyncs every adaptiveStream video's track
/// settings, off Room's state lock. The engine callback runs under that lock, which isn't
/// recursive, so resyncing inline traps.
@Suite(.serialized)
struct QuickReconnectResyncTests {
    private static func roomWithRemoteVideo() throws -> (Room, RemoteTrackPublication) {
        let room = Room(roomOptions: RoomOptions(adaptiveStream: true))
        let info = Livekit_ParticipantInfo.with {
            $0.identity = "remote"
            $0.sid = "PA_remote"
            $0.tracks = [Livekit_TrackInfo.with {
                $0.sid = "TR_video"
                $0.type = .video
                $0.source = .camera
            }]
        }
        let remote = RemoteParticipant(info: info, room: room, connectionState: .connected)
        room._state.mutate { $0.remoteParticipants[Participant.Identity(from: "remote")] = remote }
        let publication = try #require(remote.trackPublications.values.first as? RemoteTrackPublication)
        return (room, publication)
    }

    private static func waitForResync(_ publication: RemoteTrackPublication) async throws {
        for _ in 0 ..< 100 where !publication._state.isTrackSettingsResyncPending {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func quickReconnectCompletionRequestsAResync() async throws {
        let (room, publication) = try Self.roomWithRemoteVideo()
        #expect(!publication._state.isTrackSettingsResyncPending)

        room._state.mutate {
            $0.connectionState = .connected
            $0.isReconnectingWithMode = .quick
        }
        room._state.mutate { $0.isReconnectingWithMode = nil }

        try await Self.waitForResync(publication)
        #expect(publication._state.isTrackSettingsResyncPending)
    }

    @Test(arguments: [
        (ReconnectMode.full, ConnectionState.connected),
        (ReconnectMode.quick, ConnectionState.disconnected),
    ])
    func otherCompletionsRequestNoResync(mode: ReconnectMode, endState: ConnectionState) async throws {
        let (room, publication) = try Self.roomWithRemoteVideo()

        room._state.mutate {
            $0.connectionState = mode == .full ? .reconnecting : .connected
            $0.isReconnectingWithMode = mode
        }
        room._state.mutate {
            $0.connectionState = endState
            $0.isReconnectingWithMode = nil
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!publication._state.isTrackSettingsResyncPending)
    }
}
