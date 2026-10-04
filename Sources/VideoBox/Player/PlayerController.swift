import AVFoundation
import Combine
import CoreImage
import Foundation

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    let comparisonState = LUTComparisonState()

    @Published private(set) var isPlaying = false
    @Published private(set) var sourceURL: URL?
    @Published private(set) var currentTime = 0.0
    @Published private(set) var outputTime = 0.0
    @Published private(set) var outputDuration = 0.0
    @Published private(set) var activeClip: EditSegment?
    @Published private(set) var isPreparingTimeline = false
    @Published private(set) var isFullscreen = false
    @Published var monitoringVolume = 1.0 {
        didSet {
            if !monitoringVolume.isFinite { monitoringVolume = 1 }
            else if monitoringVolume < 0 || monitoringVolume > 1 { monitoringVolume = min(1, max(0, monitoringVolume)) }
            player.volume = Float(monitoringVolume)
        }
    }
    @Published private(set) var isMonitoringMuted = false
    @Published private(set) var isUsingTrackPreview = false
    @Published private(set) var subtitleText = ""
    @Published private(set) var playbackErrorMessage: String?
    @Published private(set) var navigationMessage: String?
    @Published private(set) var isLUTPreviewActive = false
    @Published var loopRange: TimelineRange?
    @Published var isLoopEnabled = false
    @Published private(set) var viewingZoom = 1.0
    @Published private(set) var viewingPan = CGSize.zero
    var setEditPoint: ((Bool) -> Void)?
    private var timeObserver: Any?
    private var itemStatusObserver: AnyCancellable?
    private var timelineTask: Task<Void, Never>?
    private var timelineGeneration = UUID()
    private var editing = EditSettings()
    private var endObserver: NSObjectProtocol?
    private var wantsPlayback = false
    private var isScrubbing = false
    private var resumeAfterScrubbing = false
    private var seekGeneration = UUID()
    private var isSeeking = false
    private var pendingFrameSteps = 0
    private var frameTask: Task<Void, Never>?
    private var frameGeneration = UUID()
    private var isNavigatingFrame = false
    private var temporaryPreviewURL: URL?
    private var temporarySubtitleURL: URL?
    private var subtitleCues: [SubtitleCue] = []
    private var activeLUT: CubeLUT?
    private var playbackURL: URL?
    private var timelineAudioResource: PreviewAudioResource?
    private var timelineVideoResource: PreviewVideoResource?
    private var previewConfiguration: ExportConfiguration?
    private var originalMediaURL: URL?
    @Published private(set) var isUsingRenderedComposition = false

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite, !self.isPreparingTimeline, !self.isSeeking {
                    if self.isPlaying, self.isLoopEnabled, let range = self.effectiveLoopRange, seconds >= range.end {
                        self.seekOutput(to: range.start); return
                    }
                    self.updatePosition(seconds)
                }
            }
        }
    }

    deinit {
        timelineTask?.cancel()
        frameTask?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let temporaryPreviewURL {
            try? FileManager.default.removeItem(at: temporaryPreviewURL)
        }
        if let temporarySubtitleURL {
            try? FileManager.default.removeItem(at: temporarySubtitleURL)
        }
    }

    func load(url: URL) {
        originalMediaURL = url; previewConfiguration = nil
        resetViewing(); loopRange = nil; isLoopEnabled = false
        editing = EditSettings()
        activeLUT = nil
        isLUTPreviewActive = false
        replaceSource(
            with: url,
            preservingTime: false,
            resumesPlayback: false,
            subtitleCues: [],
            temporarySubtitleURL: nil,
            isTemporaryPreview: false
        )
    }

    func clear() {
        pause()
        isScrubbing = false
        resumeAfterScrubbing = false
        timelineTask?.cancel()
        cancelFrameNavigation()
        timelineGeneration = UUID()
        seekGeneration = UUID()
        isSeeking = false
        pendingFrameSteps = 0
        isPreparingTimeline = false
        editing = EditSettings()
        itemStatusObserver?.cancel()
        itemStatusObserver = nil
        player.replaceCurrentItem(with: nil)
        timelineAudioResource = nil
        timelineVideoResource = nil; originalMediaURL = nil; isUsingRenderedComposition = false
        sourceURL = nil
        playbackURL = nil
        currentTime = 0
        outputTime = 0
        outputDuration = 0
        activeClip = nil
        isUsingTrackPreview = false
        subtitleText = ""
        playbackErrorMessage = nil
        activeLUT = nil
        isLUTPreviewActive = false
        subtitleCues = []
        if let temporaryPreviewURL {
            try? FileManager.default.removeItem(at: temporaryPreviewURL)
            self.temporaryPreviewURL = nil
        }
        if let temporarySubtitleURL {
            try? FileManager.default.removeItem(at: temporarySubtitleURL)
            self.temporarySubtitleURL = nil
        }
    }

    func loadTrackPreview(
        mediaURL: URL,
        subtitleURL: URL?,
        preservingTime: Bool,
        resumesPlayback: Bool
    ) throws {
        let cues = try subtitleURL.map(SubtitleCueParser.parse(contentsOf:)) ?? []
        replaceSource(
            with: mediaURL,
            preservingTime: preservingTime,
            resumesPlayback: resumesPlayback,
            subtitleCues: cues,
            temporarySubtitleURL: subtitleURL,
            isTemporaryPreview: true
        )
    }

    func togglePlayback() {
        wantsPlayback ? pause() : play()
    }

    func play() {
        cancelFrameNavigation()
        wantsPlayback = true
        guard !isPreparingTimeline, !isScrubbing else { return }
        guard let item = player.currentItem else { return }
        if item.status == .failed {
            updatePlaybackStatus(for: item)
            return
        }
        if outputDuration > 0, outputTime >= outputDuration - 0.000_01 {
            seekOutput(to: 0)
            return
        }
        guard !isSeeking else { return }
        player.playImmediately(atRate: 1)
        isPlaying = true
    }

    func pause() {
        wantsPlayback = false
        player.pause()
        isPlaying = false
    }

    func seekOutput(to seconds: TimeInterval) {
        cancelFrameNavigation()
        seekOutput(to: seconds, preservingQueuedSteps: false)
    }

    private func seekOutput(to seconds: TimeInterval, preservingQueuedSteps: Bool) {
        guard seconds.isFinite else { return }
        if !preservingQueuedSteps { pendingFrameSteps = 0 }
        updatePosition(seconds)
        if outputDuration > 0, outputTime >= outputDuration {
            wantsPlayback = false
            isPlaying = false
        }
        guard !isPreparingTimeline, let item = player.currentItem else { return }
        let time = CMTime(seconds: outputTime, preferredTimescale: 600_000)
        let generation = UUID()
        seekGeneration = generation
        isSeeking = true
        player.pause()
        item.cancelPendingSeeks()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
                guard finished else { return }
                if self.pendingFrameSteps != 0 {
                    self.performPendingFrameSteps()
                } else if self.wantsPlayback, !self.isScrubbing {
                    self.play()
                }
            }
        }
    }

    func skip(by seconds: Double) { seekOutput(to: outputTime + seconds) }

    func beginScrubbing() {
        guard !isScrubbing else { return }
        resumeAfterScrubbing = wantsPlayback
        isScrubbing = true
        pause()
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        if resumeAfterScrubbing, outputTime < outputDuration { play() }
        resumeAfterScrubbing = false
    }

    func stepFrame(_ direction: Int) {
        guard direction != 0, !isPreparingTimeline else { return }
        pause()
        pendingFrameSteps += direction > 0 ? 1 : -1
        if !isSeeking, !isNavigatingFrame { performPendingFrameSteps() }
    }

    private func performPendingFrameSteps() {
        guard player.currentItem?.status == .readyToPlay, let playbackURL else {
            pendingFrameSteps = 0
            return
        }
        guard pendingFrameSteps != 0 else { return }
        let direction = pendingFrameSteps > 0 ? 1 : -1
        pendingFrameSteps -= direction
        let generation = UUID()
        frameGeneration = generation
        isNavigatingFrame = true
        var snapshot = editing
        if snapshot.clips.isEmpty || isUsingRenderedComposition { snapshot.initialize(duration: outputDuration, canvasWidth: nil, canvasHeight: nil) }
        let frameURL = timelineVideoResource?.url ?? playbackURL
        let position = outputTime
        frameTask = Task { @MainActor [weak self] in
            do {
                let target = try await PreviewFrameNavigator.destination(sourceURL: frameURL, editing: snapshot, outputTime: position, direction: direction)
                guard let self, !Task.isCancelled, self.frameGeneration == generation else { return }
                self.isNavigatingFrame = false
                self.navigationMessage = nil
                self.seekOutput(to: target, preservingQueuedSteps: true)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.frameGeneration == generation else { return }
                self.isNavigatingFrame = false
                self.pendingFrameSteps = 0
                self.navigationMessage = error.localizedDescription
            }
        }
    }

    private func cancelFrameNavigation() {
        frameTask?.cancel()
        frameTask = nil
        frameGeneration = UUID()
        isNavigatingFrame = false
        pendingFrameSteps = 0
        navigationMessage = nil
    }

    func toggleMonitoringMute() {
        isMonitoringMuted.toggle()
        player.isMuted = isMonitoringMuted
    }

    func adjustMonitoringVolume(by amount: Double) {
        monitoringVolume = min(1, max(0, monitoringVolume + amount))
    }

    func toggleFullscreen() { isFullscreen.toggle() }
    func setFullscreen(_ value: Bool) { if isFullscreen != value { isFullscreen = value } }

    var effectiveLoopRange: TimelineRange? {
        guard outputDuration > 0 else { return nil }
        let start = min(max(0, loopRange?.start ?? 0), outputDuration)
        let end = min(outputDuration, loopRange?.end ?? outputDuration)
        return end > start + 0.04 ? TimelineRange(start: start, duration: end - start) : nil
    }
    func setLoopBoundary(isStart: Bool) {
        let old = effectiveLoopRange ?? TimelineRange(start: 0, duration: outputDuration)
        let start = isStart ? outputTime : old.start, end = isStart ? old.end : outputTime
        if end > start + 0.04 { loopRange = TimelineRange(start: start, duration: end - start) }
    }
    func jumpToClip(_ direction: Int) {
        guard let location = editing.location(atOutputTime: outputTime) else { return }
        let index = direction < 0 && location.localOutputTime > 0.2 ? location.clipIndex : location.clipIndex + direction
        seekOutput(to: editing.clipStartTimes[min(editing.clips.count - 1, max(0, index))])
    }
    func zoomViewing(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        viewingZoom = min(8, max(1, viewingZoom * factor))
        if viewingZoom == 1 { viewingPan = .zero }
    }
    func panViewing(dx: Double, dy: Double) {
        guard viewingZoom > 1 else { return }
        viewingPan.width = min(4000, max(-4000, viewingPan.width + dx))
        viewingPan.height = min(4000, max(-4000, viewingPan.height + dy))
    }
    func resetViewing() { viewingZoom = 1; viewingPan = .zero }

    func updateTimeline(editing newEditing: EditSettings) {
        let oldEditing = editing, oldClips = editing.clips
        editing = newEditing
        comparisonState.update(editing: newEditing)
        outputDuration = newEditing.outputDuration
        updatePosition(outputTime)
        guard oldEditing != newEditing else { return }
        // Canvas transforms are applied by the player surface; do not rebuild media while dragging a zoom slider.
        let timingChanged = oldClips.count != newEditing.clips.count || zip(oldClips, newEditing.clips).contains {
            $0.id != $1.id || $0.sourceRange != $1.sourceRange || $0.playbackRate != $1.playbackRate || $0.volume != $1.volume
        }
        if timingChanged || ((oldEditing.requiresRenderedPreview || newEditing.requiresRenderedPreview) && (oldClips != newEditing.clips || oldEditing.overlayClips != newEditing.overlayClips)) { rebuildTimeline() }
    }

    func configureAdvancedPreview(source: URL, configuration: ExportConfiguration) {
        let changed = originalMediaURL != source || previewConfiguration?.trackSettings != configuration.trackSettings || previewConfiguration?.color != configuration.color
        originalMediaURL = source; previewConfiguration = configuration
        if changed && editing.requiresRenderedPreview { rebuildTimeline() }
    }

    func applyLUTPreview(_ lut: CubeLUT?) {
        activeLUT = lut
        isLUTPreviewActive = lut != nil && !isUsingRenderedComposition

        if let item = player.currentItem {
            item.videoComposition = isUsingRenderedComposition ? nil : lut.map { makeVideoComposition(asset: item.asset, lut: $0) }
        }

        seekOutput(to: outputTime)
    }

    func updateComparison(fraction: Double, viewport: CGSize) {
        comparisonState.update(fraction: fraction, viewport: viewport)
        if !isUsingRenderedComposition, !isPlaying, let item = player.currentItem, let lut = activeLUT {
            item.videoComposition = makeVideoComposition(asset: item.asset, lut: lut)
        }
    }

    private func replaceSource(
        with url: URL,
        preservingTime: Bool,
        resumesPlayback: Bool,
        subtitleCues: [SubtitleCue],
        temporarySubtitleURL: URL?,
        isTemporaryPreview: Bool
    ) {
        let previousTime = preservingTime ? outputTime : 0
        let oldTemporaryURL = temporaryPreviewURL
        let oldTemporarySubtitleURL = self.temporarySubtitleURL
        pause()
        isScrubbing = false
        resumeAfterScrubbing = false
        sourceURL = url
        playbackURL = url
        outputTime = previousTime
        subtitleText = ""
        self.subtitleCues = subtitleCues
        playbackErrorMessage = nil
        temporaryPreviewURL = isTemporaryPreview ? url : nil
        self.temporarySubtitleURL = isTemporaryPreview ? temporarySubtitleURL : nil
        isUsingTrackPreview = isTemporaryPreview

        wantsPlayback = resumesPlayback
        rebuildTimeline()

        if let oldTemporaryURL, oldTemporaryURL != url {
            try? FileManager.default.removeItem(at: oldTemporaryURL)
        }
        if let oldTemporarySubtitleURL, oldTemporarySubtitleURL != temporarySubtitleURL {
            try? FileManager.default.removeItem(at: oldTemporarySubtitleURL)
        }
    }

    private func rebuildTimeline() {
        guard let playbackURL else { return }
        cancelFrameNavigation()
        timelineTask?.cancel()
        let generation = UUID()
        timelineGeneration = generation
        seekGeneration = UUID()
        isSeeking = false
        pendingFrameSteps = 0
        player.pause()
        isPlaying = false
        isPreparingTimeline = true
        let snapshot = editing
        let configuration = previewConfiguration, renderSource = originalMediaURL ?? playbackURL
        timelineTask = Task { @MainActor [weak self] in
            do {
                let preview: PreviewTimeline
                if snapshot.requiresRenderedPreview {
                    try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation()
                    preview = try await CompositionPreviewRenderer.render(source: renderSource, editing: snapshot, configuration: configuration)
                } else { preview = try await PreviewTimelineBuilder.make(asset: AVURLAsset(url: playbackURL), editing: snapshot) }
                guard let self, !Task.isCancelled, self.timelineGeneration == generation else { return }
                self.outputDuration = preview.duration
                let item = AVPlayerItem(asset: preview.asset)
                item.audioMix = preview.audioMix
                item.audioTimePitchAlgorithm = .spectral
                if preview.videoResource == nil, let lut = self.activeLUT {
                    item.videoComposition = self.makeVideoComposition(asset: preview.asset, lut: lut)
                }
                self.itemStatusObserver?.cancel()
                self.itemStatusObserver = item.publisher(for: \.status, options: [.initial, .new])
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self, weak item] _ in
                        Task { @MainActor [weak self] in
                            guard let self, let item, self.player.currentItem === item else { return }
                            self.updatePlaybackStatus(for: item)
                        }
                    }
                if let old = self.endObserver { NotificationCenter.default.removeObserver(old) }
                self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.player.currentItem === item, !self.isSeeking else { return }
                        if self.isLoopEnabled, let range = self.effectiveLoopRange {
                            self.seekOutput(to: range.start); self.play(); return
                        }
                        self.pause()
                        self.updatePosition(self.outputDuration)
                    }
                }
                self.player.replaceCurrentItem(with: item)
                self.timelineAudioResource = preview.audioResource
                self.timelineVideoResource = preview.videoResource; self.isUsingRenderedComposition = preview.videoResource != nil
                self.isLUTPreviewActive = self.activeLUT != nil && !self.isUsingRenderedComposition
                var comparisonEdit = snapshot
                if self.isUsingRenderedComposition { comparisonEdit.initialize(duration: snapshot.outputDuration, canvasWidth: snapshot.canvasWidth, canvasHeight: snapshot.canvasHeight) }
                self.comparisonState.update(editing: comparisonEdit)
                self.player.defaultRate = 1
                self.player.volume = Float(self.monitoringVolume)
                self.player.isMuted = self.isMonitoringMuted
                self.isPreparingTimeline = false
                self.playbackErrorMessage = nil
                self.seekOutput(to: self.outputTime)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.timelineGeneration == generation else { return }
                self.isPreparingTimeline = false
                self.pause()
                self.player.replaceCurrentItem(with: nil)
                self.playbackErrorMessage = error.localizedDescription
            }
        }
    }

    private func updatePosition(_ seconds: Double) {
        outputTime = min(outputDuration, max(0, seconds))
        if let location = editing.location(atOutputTime: outputTime) {
            currentTime = location.sourceTime
            activeClip = editing.clips[location.clipIndex]
        } else {
            currentTime = outputTime
            activeClip = nil
        }
        updateSubtitleText(at: currentTime)
    }

    private func updateSubtitleText(at time: TimeInterval) {
        let activeText = subtitleCues
            .filter { $0.startTime <= time && time < $0.endTime }
            .map(\.text)
            .joined(separator: "\n")
        if subtitleText != activeText {
            subtitleText = activeText
        }
    }

    private func makeVideoComposition(asset: AVAsset, lut: CubeLUT) -> AVVideoComposition {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let comparison = comparisonState
        return AVVideoComposition(asset: asset) { request in
            guard let processed = LUTPreviewRenderer.apply(lut, to: request.sourceImage) else {
                request.finish(with: NSError(domain: "VideoBox.LUT", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "实时 LUT 预览失败，请使用导出效果预览核对。"]))
                return
            }
            let region = comparison.originalRegion(extent: request.sourceImage.extent, outputTime: request.compositionTime.seconds)
            let output = request.sourceImage.cropped(to: region).composited(over: processed)
            request.finish(with: output, context: context)
        }
    }

    private func updatePlaybackStatus(for item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            playbackErrorMessage = nil
        case .failed:
            isPlaying = false
            playbackErrorMessage = item.error?.localizedDescription
                ?? "macOS 无法解码当前视频轨道。"
        case .unknown:
            break
        @unknown default:
            break
        }
    }
}
