//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import AVKit
import Defaults
import Foundation
@preconcurrency import JellyfinAPI
import SpatialAudioBridge
import SpatialAudioPlayback
import SwiftUI

@MainActor
class AVMediaPlayerProxy: NSObject,
    VideoMediaPlayerLayoutConfigurable,
    MediaPlayerPictureInPictureCapable
{
    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    let videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)

    let isPiPActive: PublishedBox<Bool> = .init(initialValue: false)
    let isPiPAvailable: PublishedBox<Bool> = .init(initialValue: false)

    var isScrubbing: Binding<Bool> = .constant(false)
    var scrubbedSeconds: Binding<Duration> = .constant(.zero)

    let avPlayerLayer: AVPlayerLayer
    let player: AVPlayer

    #if os(tvOS)
    weak var displayManager: AVDisplayManager? {
        didSet {
            observeDisplayModeSwitch()
            Task { await updatePreferredDisplayCriteria() }
        }
    }

    private var displayModeSwitchObserver: NSKeyValueObservation?
    #endif

    private(set) var pipController: AVPictureInPictureController?

    private var pendingSeekSeconds: Duration?
    /// The latest seek and when it was requested, so that a stall recovery resumes there.
    private var lastSeek: (seconds: Duration, date: ContinuousClock.Instant)?

    /// Plays the current item's spatial audio until cancelled.
    private var spatialAudioTask: Task<Void, Never>?

    private var cachedAudioStreams: [MediaStream] = []
    private var cachedSubtitleStreams: [MediaStream] = []
    private var cachedAudioGroup: AVMediaSelectionGroup?
    private var cachedSubtitleGroup: AVMediaSelectionGroup?

    private var pipAvailableObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var videoSizeObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var accessLogObserver: NSObjectProtocol?

    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }
        }
    }

    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(audioSessionMode: .moviePlayback, supportsMultichannelContent: true),
    ]

    override init() {
        self.player = AVPlayer()
        self.avPlayerLayer = AVPlayerLayer(player: player)

        super.init()

        player.appliesMediaSelectionCriteriaAutomatically = false

        player.allowsExternalPlayback = false

        addTimeObserver()
    }

    func play() {
        player.rate = Float(manager?.rate ?? 1.0)
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
        stopSpatialAudio()
    }

    func jumpForward(_ seconds: Duration) {
        guard player.currentItem?.status == .readyToPlay else {
            setSeconds((manager?.seconds ?? .zero) + seconds)
            return
        }

        let currentTime = player.currentTime()
        let newTime = currentTime + CMTime(seconds: seconds.seconds, preferredTimescale: 600)

        seek(to: newTime)
    }

    func jumpBackward(_ seconds: Duration) {
        guard player.currentItem?.status == .readyToPlay else {
            setSeconds(max(.zero, (manager?.seconds ?? .zero) - seconds))
            return
        }

        let currentTime = player.currentTime()
        let newTime = max(.zero, currentTime - CMTime(seconds: seconds.seconds, preferredTimescale: 600))

        seek(to: newTime)
    }

    func setRate(_ rate: Double) {
        // `play()` applies the rate when playback resumes while setting one during a pause forces a resume
        guard player.rate != 0 else { return }

        player.rate = Float(rate)
    }

    func setSeconds(_ seconds: Duration) {
        guard player.currentItem?.status == .readyToPlay else {
            pendingSeekSeconds = seconds
            return
        }

        seek(to: CMTime(seconds: seconds.seconds, preferredTimescale: 600))
    }

    private func seek(to time: CMTime) {
        lastSeek = (.seconds(time.seconds), .now)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setAudioStream(_ stream: MediaStream) {
        guard let item = player.currentItem,
              let group = cachedAudioGroup
        else { return }
        guard let index = stream.index, group.options.indices.contains(index) else { return }

        item.select(group.options[index], in: group)
    }

    func setSubtitleStream(_ stream: MediaStream) {
        guard let item = player.currentItem,
              let group = cachedSubtitleGroup
        else { return }
        guard let index = stream.index, group.options.indices.contains(index) else {
            item.select(nil, in: group)
            return
        }

        item.select(group.options[index], in: group)
    }

    private func selectionOption(
        matching index: Int,
        in group: AVMediaSelectionGroup,
        from streams: [MediaStream]
    ) -> AVMediaSelectionOption? {
        if streams.count == group.options.count,
           let position = streams.firstIndex(where: { $0.index == index })
        {
            return group.options[position]
        }

        if group.options.count == 1 {
            return group.options.first
        }

        if let language = streams.first(where: { $0.index == index })?.language {
            return AVMediaSelectionGroup.mediaSelectionOptions(
                from: group.options,
                filteredAndSortedAccordingToPreferredLanguages: [language]
            )
            .first
        }

        return nil
    }

    @ViewBuilder
    func videoPlayerBody(layout: VideoPlayer.VideoLayout) -> some View {
        AVPlayerView(videoLayout: layout)
            .environmentObject(self)
    }
}

// MARK: - Picture In Picture

extension AVMediaPlayerProxy {

    func setupPiP() {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }

        pipController = AVPictureInPictureController(playerLayer: avPlayerLayer)
        pipController?.delegate = self
        pipController?.requiresLinearPlayback = false

        #if os(iOS)
        pipController?.canStartPictureInPictureAutomaticallyFromInline = false
        #endif

        pipAvailableObserver = pipController?.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            let isAvailable = controller.isPictureInPicturePossible
            DispatchQueue.main.async {
                self?.isPiPAvailable.value = isAvailable
            }
        }
    }

    func startPiP() {
        pipController?.startPictureInPicture()
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
    }

    private func teardownPiP() {
        if isPiPActive.value {
            pipController?.stopPictureInPicture()
        }

        isPiPActive.value = false
        isPiPAvailable.value = false

        pipAvailableObserver?.invalidate()
        pipAvailableObserver = nil
    }
}

extension AVMediaPlayerProxy: AVPictureInPictureControllerDelegate {

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            isPiPActive.value = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            isPiPActive.value = false
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            isPiPActive.value = false
            manager?.logger.error("Unable to start Picture in Picture: \(error.localizedDescription)")
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - Playback Lifecycle

extension AVMediaPlayerProxy {

    func playNew(item: MediaPlayerItem) {
        removeItemObservers()
        addTimeObserver()

        pendingSeekSeconds = nil
        lastSeek = nil
        stopSpatialAudio()

        cachedAudioStreams = item.audioStreams.filter { $0.isExternal != true }
        cachedSubtitleStreams = item.subtitleStreams.filter { $0.isExternal != true }

        if #available(iOS 26, tvOS 26, *), let spatialAudioURL = item.spatialAudioURL {
            spatialAudioTask = Task { [weak self] in
                await self?.playSpatialAudio(from: spatialAudioURL, for: item)
            }
        } else {
            load(item.url, for: item)
        }
    }

    private func load(_ url: URL, for item: MediaPlayerItem) {
        let playerItem = AVPlayerItem(url: url)
        playerItem.externalMetadata = item.baseItem.avMetadata

        removeItemObservers()

        player.replaceCurrentItem(with: playerItem)

        observeTimeControlStatus()
        observeVideoSize(of: playerItem)
        observeItemEnd(of: playerItem)
        observeAccessLog(of: playerItem)
        observeStatus(of: playerItem, for: item)
    }

    func playbackStopped() {
        teardownPiP()

        #if os(tvOS)
        displayManager?.preferredDisplayCriteria = nil
        #endif

        pendingSeekSeconds = nil
        stopSpatialAudio()

        player.pause()

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        removeItemObservers()
    }

    private func addTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] newTime in
            MainActor.assumeIsolated {
                guard let self, newTime.isNumeric else { return }

                let newSeconds = Duration.seconds(newTime.seconds)

                if !self.isScrubbing.wrappedValue {
                    self.scrubbedSeconds.wrappedValue = newSeconds
                }

                self.manager?.seconds = newSeconds
            }
        }
    }

    private func removeItemObservers() {
        statusObserver?.invalidate()
        statusObserver = nil

        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil

        videoSizeObserver?.invalidate()
        videoSizeObserver = nil

        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
            self.itemEndObserver = nil
        }

        if let accessLogObserver {
            NotificationCenter.default.removeObserver(accessLogObserver)
            self.accessLogObserver = nil
        }

        cachedAudioGroup = nil
        cachedSubtitleGroup = nil
    }

    private func observeTimeControlStatus() {
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }

            let status = player.timeControlStatus

            DispatchQueue.main.async {

                #if os(tvOS)
                self.isBuffering.value = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    || self.displayManager?.isDisplayModeSwitchInProgress == true
                #else
                self.isBuffering.value = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                #endif

                switch status {
                case .playing:
                    self.manager?.setPlaybackRequestStatus(status: .playing)
                case .paused:
                    self.manager?.setPlaybackRequestStatus(status: .paused)
                default:
                    break
                }
            }
        }
    }

    private func observeVideoSize(of playerItem: AVPlayerItem) {
        videoSizeObserver = playerItem.observe(\.presentationSize, options: [.new]) { [weak self] playerItem, _ in
            guard let self else { return }

            DispatchQueue.main.async {
                let size = playerItem.presentationSize
                if size != .zero {
                    self.videoSize.value = size
                }
            }
        }
    }

    private func observeItemEnd(of playerItem: AVPlayerItem) {
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !(self.manager?.playbackItem?.baseItem.isLiveStream ?? false) else { return }

                if let runtime = self.manager?.item.runtime {
                    self.manager?.seconds = runtime
                } else if let duration = self.player.currentItem?.duration, duration.isNumeric {
                    self.manager?.seconds = Duration.seconds(duration.seconds)
                }

                self.manager?.ended()
            }
        }
    }

    private func observeAccessLog(of playerItem: AVPlayerItem) {
        accessLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let playerItem = notification.object as? AVPlayerItem,
                      let event = playerItem.accessLog()?.events.last
                else { return }

                if event.numberOfDroppedVideoFrames >= 0 {
                    self.droppedFrames.value = event.numberOfDroppedVideoFrames
                }
            }
        }
    }

    private func observeStatus(of playerItem: AVPlayerItem, for item: MediaPlayerItem) {
        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] playerItem, _ in
            guard let self else { return }

            switch playerItem.status {
            case .failed:
                let error = playerItem.error ?? self.player.error
                DispatchQueue.main.async {
                    // When spatial audio fails, the server's stream plays on from where it stopped
                    if (playerItem.asset as? AVURLAsset)?.url != item.url {
                        self.manager?.logger.warning("Spatial audio failed: \(error?.localizedDescription ?? L10n.unknownError)")
                        self.stopSpatialAudio()

                        let time = playerItem.currentTime()
                        if time.isNumeric, time > .zero {
                            self.pendingSeekSeconds = .seconds(time.seconds)
                        } else if let seconds = self.manager?.seconds, seconds > .zero {
                            self.pendingSeekSeconds = seconds
                        }

                        self.load(item.url, for: item)
                        return
                    }

                    self.manager?.error(ErrorMessage("AVPlayer error: \(error?.localizedDescription ?? L10n.unknownError)"))
                }

            case .readyToPlay:
                Task { @MainActor [weak self] in
                    await self?.itemDidBecomeReady(playerItem: playerItem, item: item)
                }

            default: ()
            }
        }
    }

    /// Where playback of `item` starts: at a seek requested before it was ready, or where it was left off.
    private func initialSeconds(for item: MediaPlayerItem) -> Duration {
        pendingSeekSeconds ?? max(
            .zero,
            (item.baseItem.startSeconds ?? .zero) - Duration.seconds(Defaults[.VideoPlayer.resumeOffset])
        )
    }

    private func itemDidBecomeReady(playerItem: AVPlayerItem, item: MediaPlayerItem) async {
        let startSeconds = initialSeconds(for: item)
        pendingSeekSeconds = nil

        cachedAudioGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible)
        cachedSubtitleGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible)

        #if os(tvOS)
        await updatePreferredDisplayCriteria()
        #endif

        var indexMap = MediaTrackIndexMap()
        for (streams, cachedStreams, group) in [
            (item.audioStreams, cachedAudioStreams, cachedAudioGroup),
            (item.subtitleStreams, cachedSubtitleStreams, cachedSubtitleGroup),
        ] {
            guard let group else { continue }

            for stream in streams {
                guard let index = stream.index,
                      let option = selectionOption(matching: index, in: group, from: cachedStreams),
                      let playerIndex = group.options.firstIndex(of: option)
                else { continue }

                indexMap.setPlayerIndex(playerIndex, for: index)
            }
        }
        item.setTrackIndexes(indexMap)

        player.seek(
            to: CMTime(seconds: startSeconds.seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self,
                      let manager = self.manager,
                      manager.state != .stopped,
                      manager.playbackRequestStatus == .playing
                else { return }

                self.player.rate = Float(manager.rate)
            }
        }
    }

    #if os(tvOS)
    private func observeDisplayModeSwitch() {
        guard let displayManager else {
            displayModeSwitchObserver = nil
            return
        }

        displayModeSwitchObserver = displayManager.observe(
            \.isDisplayModeSwitchInProgress,
            options: [.new]
        ) { [weak self] displayManager, _ in
            let inProgress = displayManager.isDisplayModeSwitchInProgress
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard !inProgress else {
                        self.isBuffering.value = true
                        return
                    }

                    // isDisplayModeSwitchInProgress can be initially blank so wait 0.5 seconds for this to populate
                    // https://developer.apple.com/documentation/avkit/avdisplaymanager/isdisplaymodeswitchinprogress
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        MainActor.assumeIsolated {
                            self.isBuffering.value = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                                || self.displayManager?.isDisplayModeSwitchInProgress == true
                        }
                    }
                }
            }
        }
    }

    private func updatePreferredDisplayCriteria() async {
        guard let displayManager,
              let playerItem = player.currentItem,
              playerItem.status == .readyToPlay,
              let track = try? await playerItem.asset.loadTracks(withMediaType: .video).first,
              let formatDescription = try? await track.load(.formatDescriptions).first
        else { return }

        let nominalFrameRate = await (try? track.load(.nominalFrameRate)) ?? 0

        displayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: nominalFrameRate,
            formatDescription: formatDescription
        )
    }
    #endif
}

// MARK: - Spatial Audio

extension AVMediaPlayerProxy {

    /// Plays `item` with its TrueHD Atmos or DTS:X track converted to APAC beside the server's video, until cancelled.
    /// Plays the server's audio instead if the track cannot be converted.
    @available(iOS 26, tvOS 26, *)
    private func playSpatialAudio(from fileURL: URL, for item: MediaPlayerItem) async {
        let stream: APACStream

        do {
            let file = try await MatroskaFile.open(HTTPByteSource(url: fileURL))

            // Jellyfin and Matroska both list the file's audio tracks in order
            guard file.audioTracks.count == item.audioStreams.count,
                  let position = item.audioStreams.firstIndex(where: { $0.index == item.selectedAudioStreamIndex }),
                  file.audioTracks[position].codec != nil
            else { throw ErrorMessage("Unable to find the selected audio track in the file") }

            var options = APACStream.Options()
            // Without Jellyfin's transcoding fallbacks, which AVPlayer switches to when a segment is slow
            options.includesVideoVariant = { $0.query?.contains("AllowVideoStreamCopy=false") != true }

            stream = try await APACStream.start(
                file: file,
                track: file.audioTracks[position],
                videoMaster: item.url,
                startTime: CMTime(seconds: initialSeconds(for: item).seconds, preferredTimescale: 600),
                options: options
            )
        } catch {
            guard !Task.isCancelled else { return }

            manager?.logger.warning("Unable to play spatial audio: \(error)")
            load(item.url, for: item)
            return
        }

        guard let masterURL = stream.masterPlaylistURL, !Task.isCancelled else {
            await stream.stop()
            return
        }

        // Switches the receiver to Atmos while the stream's items play
        let atmos = AtmosOutputActivator()
        atmos.attach(to: player) { ($0.asset as? AVURLAsset)?.url == masterURL }

        load(masterURL, for: item)
        await recoverStalls(of: masterURL, for: item)

        if (player.currentItem?.asset as? AVURLAsset)?.url == masterURL {
            player.replaceCurrentItem(with: nil)
        }
        atmos.detach()
        await stream.stop()
    }

    /// Reloads the item when AVPlayer has waited 20 s, as it can indefinitely after rapid seeks, until cancelled.
    /// Seeks took up to 15 s to resume.
    private func recoverStalls(of url: URL, for item: MediaPlayerItem) async {
        var status = player.timeControlStatus
        var statusDate = ContinuousClock.now

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            if player.timeControlStatus != status {
                status = player.timeControlStatus
                statusDate = .now
            }

            // Five seconds of playback after a seek mean it resolved
            if status == .playing, let lastSeek, ContinuousClock.now - max(statusDate, lastSeek.date) > .seconds(5) {
                self.lastSeek = nil
            }

            guard status == .waitingToPlayAtSpecifiedRate, ContinuousClock.now - statusDate > .seconds(20) else { continue }

            manager?.logger.warning("Reloading stalled spatial audio playback")
            pendingSeekSeconds = lastSeek?.seconds ?? manager?.seconds
            load(url, for: item)
            statusDate = .now
        }
    }

    private func stopSpatialAudio() {
        spatialAudioTask?.cancel()
        spatialAudioTask = nil
    }
}

// MARK: - AVPlayerView

extension AVMediaPlayerProxy {

    struct AVPlayerView: View {

        @EnvironmentObject
        private var manager: MediaPlayerManager
        @EnvironmentObject
        private var proxy: AVMediaPlayerProxy

        let videoLayout: VideoPlayer.VideoLayout

        var body: some View {
            AVPlayerLayerView(proxy: proxy)
                .frame(width: videoLayout.renderSize.width, height: videoLayout.renderSize.height)
                .scaleEffect(videoLayout.renderScale)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .onReceive(manager.$playbackItem) { playbackItem in
                    guard let playbackItem else { return }

                    proxy.playNew(item: playbackItem)
                }
                .onReceive(manager.$state) { state in
                    guard state == .stopped else { return }

                    proxy.playbackStopped()
                }
                .onChange(of: manager.rate) {
                    proxy.setRate(manager.rate)
                }
        }
    }

    private struct AVPlayerLayerView: UIViewRepresentable {

        @Environment(VideoPlayer.ViewState.self)
        private var viewState

        let proxy: AVMediaPlayerProxy

        func makeUIView(context: Context) -> UIView {
            proxy.isScrubbing = Binding(
                get: { viewState.isScrubbing },
                set: { viewState.isScrubbing = $0 }
            )
            proxy.scrubbedSeconds = Binding(
                get: { viewState.scrubbedSeconds.value },
                set: { viewState.scrubbedSeconds.value = $0 }
            )

            return AVPlayerUIView(proxy: proxy)
        }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    private class AVPlayerUIView: UIView {

        let proxy: AVMediaPlayerProxy

        init(proxy: AVMediaPlayerProxy) {
            self.proxy = proxy
            super.init(frame: .zero)
            layer.addSublayer(proxy.avPlayerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            proxy.avPlayerLayer.frame = bounds
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }

            Task { @MainActor [weak self] in
                self?.proxy.setupPiP()
                #if os(tvOS)
                self?.proxy.displayManager = window.avDisplayManager
                #endif
            }
        }
    }
}
