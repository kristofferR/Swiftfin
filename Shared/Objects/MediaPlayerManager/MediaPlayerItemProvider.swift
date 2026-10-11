//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI

typealias MediaPlayerItemProviderResolver = @MainActor @Sendable (
    BaseItemDto,
    VideoPlayerType,
    (@Sendable (inout BaseItemDto) -> Void)?
) async throws -> MediaPlayerItem

@MainActor
struct MediaPlayerItemProvider {

    @SharedBaseItem
    var item: BaseItemDto
    let mediaSource: MediaSourceInfo?
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
    let requestedBitrate: PlaybackBitrate
    private var modifyItem: (@Sendable (inout BaseItemDto) -> Void)?
    private let resolver: MediaPlayerItemProviderResolver

    init(
        item: BaseItemDto,
        mediaSource: MediaSourceInfo? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        requestedBitrate: PlaybackBitrate = Defaults[.VideoPlayer.Playback.appMaximumBitrate],
        resolver: @escaping MediaPlayerItemProviderResolver
    ) {
        self.item = item
        self.mediaSource = mediaSource
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.requestedBitrate = requestedBitrate
        self.modifyItem = nil
        self.resolver = resolver
    }

    func modifyingItem(
        _ modifier: @escaping @Sendable (inout BaseItemDto) -> Void
    ) -> Self {
        var copy = self
        let currentModifier = modifyItem

        copy.modifyItem = { item in
            currentModifier?(&item)
            modifier(&item)
        }

        return copy
    }

    /// The engine to play this item with.
    /// A selected TrueHD Atmos or DTS:X track plays as spatial audio through AVPlayer, beside the server's HLS video.
    /// The selected engine stays when AVPlayer would direct play the file instead, or have the server burn an image
    /// subtitle into the video, which the other engines avoid.
    var videoPlayerType: VideoPlayerType {
        let preferredPlayerType = Defaults[.VideoPlayer.videoPlayerType]

        guard let mediaSource = mediaSource ?? item.mediaSources?.first else { return preferredPlayerType }

        let audioStreamIndex = audioStreamIndex ?? mediaSource.defaultAudioStreamIndex
        let audioStream = mediaSource.audioStreams?.first { $0.index == audioStreamIndex }
        let subtitleStreamIndex = subtitleStreamIndex ?? mediaSource.defaultSubtitleStreamIndex
        let subtitleStream = mediaSource.subtitleStreams?.first { $0.index == subtitleStreamIndex }

        let avPlayerProfile = DeviceProfile.build(
            for: .avPlayer,
            compatibilityMode: Defaults[.VideoPlayer.Playback.compatibilityMode]
        )

        guard mediaSource.supportsSpatialAudio(audioStreamIndex: audioStreamIndex),
              !avPlayerProfile.canPlay(type: .video, audioCodec: audioStream?.codec, container: mediaSource.container),
              subtitleStream?.isTextSubtitleStream != false
        else { return preferredPlayerType }

        return .avPlayer
    }

    func callAsFunction(videoPlayerType: VideoPlayerType) async throws -> MediaPlayerItem {
        guard let item = $item.value else { throw ItemStore.StoreError.itemUnavailable }

        let playbackItem = try await resolver(item, videoPlayerType, modifyItem)
        guard $item.value != nil else { throw ItemStore.StoreError.itemUnavailable }

        return playbackItem
    }
}
