//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreTransferable
import Defaults
import JellyfinAPI

extension MediaSourceInfo: Displayable {

    var displayTitle: String {
        name ?? .emptyDash
    }
}

extension MediaSourceInfo {

    var supportedBitrates: [PlaybackBitrate] {
        let bitrates: [PlaybackBitrate] = if videoStreams?.isNotEmpty == true {
            PlaybackBitrate.videoBitrates
        } else if audioStreams?.isNotEmpty == true {
            PlaybackBitrate.audioBitrates
        } else {
            PlaybackBitrate.allCases
        }

        guard let bitrate else { return bitrates }

        return bitrates.filter {
            $0 == .max || $0.rawValue <= bitrate
        }
    }

    var audioStreams: [MediaStream]? {
        mediaStreams?.filter { $0.type == .audio }
    }

    var subtitleStreams: [MediaStream]? {
        mediaStreams?.filter { $0.type == .subtitle }
    }

    var videoStreams: [MediaStream]? {
        mediaStreams?.filter { $0.type == .video }
    }

    /// The selected audio stream, or the one that plays when none is selected: the default, else the first.
    func audioStream(selectedIndex: Int?) -> MediaStream? {
        let index = selectedIndex ?? defaultAudioStreamIndex ?? audioStreams?.first?.index
        return audioStreams?.first { $0.index == index }
    }

    /// Whether AVPlayer can try to play this audio stream as spatial audio.
    /// SpatialAudioBridge converts TrueHD Atmos and DTS:X tracks in Matroska files on iOS and tvOS 26. Jellyfin reports
    /// some DTS:X tracks as plain DTS-HD MA, so the library is offered every TrueHD and DTS-HD MA track and rejects the
    /// others as it starts. It reads the whole file, so the file's bitrate must fit `maxBitrate`, when that is known.
    func supportsSpatialAudio(audioStreamIndex: Int?, maxBitrate: Int?) -> Bool {
        guard #available(iOS 26, tvOS 26, *),
              Defaults[.VideoPlayer.spatialAudio],
              container == "mkv",
              let bitrate,
              bitrate <= maxBitrate ?? .max,
              let stream = audioStream(selectedIndex: audioStreamIndex),
              stream.isExternal != true
        else { return false }

        return stream.codec == "truehd" || (stream.codec == "dts" && stream.profile?.hasPrefix("DTS-HD MA") == true)
    }
}

extension MediaSourceInfo: @retroactive Transferable, TextTransferable {

    typealias Property = MediaStream.Property

    @ArrayBuilder<Property>
    var transferProperties: [Property] {
        if let value = path {
            (label: L10n.path, value: value)
        }

        if let value = container {
            (label: L10n.container, value: value)
        }

        if let value = size {
            (label: L10n.size, value: Int64(value).formatted(.byteCount(style: .binary)))
        }

        if let value = bitrate {
            (label: L10n.bitrate, value: value.formatted(.bitRate))
        }

        if let value = video3DFormat {
            (label: L10n.format3D, value: value.rawValue)
        }

        if let value = isoType {
            (label: L10n.isoType, value: value.rawValue)
        }

        if let value = timestamp {
            (label: L10n.timestamp, value: value.rawValue)
        }

        if let value = isRemote {
            (label: L10n.remote, value: value ? L10n.yes : L10n.no)
        }
    }

    public var transferTitle: String {
        displayTitle
    }

    public var transferBody: String {
        let properties = transferProperties
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")

        let source = [displayTitle, properties]
            .joined(separator: "\n\n")

        return ([source] + (mediaStreams ?? [])
            .map(\.transferBody))
            .joined(separator: "\n\n")
    }
}
