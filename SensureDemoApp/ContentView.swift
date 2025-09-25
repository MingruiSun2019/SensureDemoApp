//
//  ContentView.swift
//  SensureDemoApp
//
//  Created by MINGRUI SUN on 25/9/2025.
//

import SwiftUI
import AVKit
import AVFoundation
import CoreHaptics
import UniformTypeIdentifiers
import PhotosUI

struct ContentView: View {
    @StateObject private var viewModel = TactileVideoViewModel()
    @State private var selectedPhotoPickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 20) {
            Text("Sensure Tactile Video demo")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            VideoPlayer(player: viewModel.player)
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            WaveformView(
                samples: viewModel.displayWaveformSamples,
                progress: viewModel.progress,
                isLoading: false,
                onScrub: { progress, isFinal in
                    viewModel.scrub(to: progress, isFinal: isFinal)
                }
            )
            .frame(height: 80)

            Button(action: viewModel.togglePlayback) {
                Text(viewModel.playbackButtonTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(!viewModel.isPlayerReady)

            HStack(spacing: 12) {
                PhotosPicker(selection: $selectedPhotoPickerItem, matching: .videos) {
                    Text("Upload Video")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button("Revert to Default") {
                    viewModel.revertToDefaultVideo()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(24)
        .onAppear {
            viewModel.setup()
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .background(Color(.systemGroupedBackground))
        .onChange(of: selectedPhotoPickerItem) { _, newItem in
            guard let newItem else { return }

            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("selected_video.mov")
                    try? data.write(to: tempURL)
                    await MainActor.run {
                        viewModel.loadCustomVideo(from: tempURL)
                    }
                }
            }
        }
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let samples: [CGFloat]
    let progress: Double
    let isLoading: Bool
    let onScrub: (Double, Bool) -> Void

    private let backgroundColor = Color(.secondarySystemBackground)
    private let waveformColor = Color.accentColor.opacity(0.55)
    private let indicatorColor = Color.accentColor

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let clampedProgress = progress.clamped(to: 0...1)
            let indicatorX = max(1.5, min(width - 1.5, CGFloat(clampedProgress) * width))

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(backgroundColor)

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    WaveformShape(samples: samples)
                        .stroke(waveformColor, lineWidth: 1.5)
                        .background(
                            WaveformShape(samples: samples)
                                .fill(waveformColor.opacity(0.35))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Rectangle()
                        .fill(indicatorColor)
                        .frame(width: 3, height: height)
                        .position(x: indicatorX, y: height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let xPosition = value.location.x.clamped(to: 0...width)
                        let newProgress = Double(xPosition / width)
                        onScrub(newProgress, false)
                    }
                    .onEnded { value in
                        let xPosition = value.location.x.clamped(to: 0...width)
                        let newProgress = Double(xPosition / width)
                        onScrub(newProgress, true)
                    }
            )
        }
    }
}

struct WaveformShape: Shape {
    let samples: [CGFloat]

    func path(in rect: CGRect) -> Path {
        guard !samples.isEmpty else { return Path() }

        let centerY = rect.midY
        let barWidth = max(rect.width / CGFloat(samples.count), 1)
        var path = Path()

        for (index, sample) in samples.enumerated() {
            let normalized = sample.clamped(to: 0...1)
            let barHeight = max(normalized * rect.height, 2)
            let xPosition = rect.minX + CGFloat(index) * barWidth
            let barRect = CGRect(
                x: xPosition,
                y: centerY - (barHeight / 2),
                width: barWidth,
                height: barHeight
            )
            path.addRoundedRect(in: barRect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }

        return path
    }
}

// MARK: - View Model

final class TactileVideoViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var displayWaveformSamples: [CGFloat] = PseudoWaveformGenerator.samples(count: 180)
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    @Published var didFinishPlaying = false
    @Published var isPlayerReady = false

    private var customVideoURL: URL?
    private var isUsingCustomVideo = false

    private var timeObserver: Any?
    private var endObserver: Any?
    private var wasPlayingBeforeScrub = false
    private var isScrubbing = false
    private var setupPerformed = false
    private var hapticEngine: CHHapticEngine?
    private var hapticsAvailable = false
    private var lastHapticTrigger: TimeInterval = 0
    private var hapticAmplitudeSamples: [Double] = []
    private var audioSessionConfigured = false

    var progress: Double {
        guard duration > 0 else { return 0 }
        return (currentTime / duration).clamped(to: 0...1)
    }

    var playbackButtonTitle: String {
        if didFinishPlaying {
            return "Replay"
        }
        if player?.timeControlStatus == .playing {
            return "Pause"
        }
        return "Play"
    }

    func setup() {
        guard !setupPerformed else { return }
        setupPerformed = true

        let url: URL?
        if isUsingCustomVideo, let customURL = customVideoURL {
            url = customURL
        } else {
            url = Bundle.main.url(forResource: "demo_video_1", withExtension: "mp4")
        }

        guard let videoURL = url else {
            return
        }

        configureAudioSession()

        let asset = AVAsset(url: videoURL)
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { [weak self] in
            guard let self else { return }

            var durationStatusError: NSError?
            let durationStatus = asset.statusOfValue(forKey: "duration", error: &durationStatusError)

            guard durationStatus == .loaded else {
                return
            }

            DispatchQueue.main.async {
                let rawDuration = CMTimeGetSeconds(asset.duration)
                self.duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 1
                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                self.player = player
                self.isPlayerReady = true
                self.prepareHaptics()
                self.observePlayback(on: player, item: item)
            }

            self.analyzeAudioForHaptics(from: asset)
        }
    }

    func cleanup() {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil

        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = nil

        hapticEngine?.stop(completionHandler: { _ in })
        hapticEngine = nil
        hapticsAvailable = false
        lastHapticTrigger = 0
        hapticAmplitudeSamples = []
        player = nil
        isPlayerReady = false
        setupPerformed = false
        audioSessionConfigured = false
    }

    func togglePlayback() {
        guard let player else { return }

        if didFinishPlaying {
            didFinishPlaying = false
            seek(to: 0) { [weak self] in
                self?.play()
            }
            return
        }

        switch player.timeControlStatus {
        case .playing:
            pause()
        default:
            play()
        }
    }

    func scrub(to progress: Double, isFinal: Bool) {
        guard isPlayerReady else { return }
        let clamped = progress.clamped(to: 0...1)
        let targetTime = duration * clamped

        if !isScrubbing {
            wasPlayingBeforeScrub = player?.timeControlStatus == .playing
            pause()
            isScrubbing = true
        }

        seek(to: targetTime) { [weak self] in
            guard let self else { return }
            self.currentTime = targetTime
            if isFinal {
                self.isScrubbing = false
                if self.wasPlayingBeforeScrub {
                    self.play()
                }
            }
        }
    }

    func loadCustomVideo(from url: URL) {
        customVideoURL = url
        isUsingCustomVideo = true
        resetPlayerState()
        setupPerformed = false
        setup()
    }

    func revertToDefaultVideo() {
        customVideoURL = nil
        isUsingCustomVideo = false
        resetPlayerState()
        setupPerformed = false
        setup()
    }

    private func resetPlayerState() {
        cleanup()
        currentTime = 0
        duration = 1
        didFinishPlaying = false
        isPlayerReady = false
        displayWaveformSamples = PseudoWaveformGenerator.samples(count: 180)
    }

    private func play() {
        prepareHaptics()
        try? hapticEngine?.start()
        player?.play()
        didFinishPlaying = false
    }

    private func pause() {
        player?.pause()
        resetHapticsState()
    }

    private func seek(to seconds: Double, completion: (() -> Void)? = nil) {
        guard let player else {
            completion?()
            return
        }

        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            completion?()
        }
    }

    private func prepareHaptics() {
        guard !hapticsAvailable else { return }
        let capabilities = CHHapticEngine.capabilitiesForHardware()
        guard capabilities.supportsHaptics else { return }

        do {
            let engine = try CHHapticEngine()
            hapticEngine = engine

            engine.stoppedHandler = { [weak self] _ in
                self?.lastHapticTrigger = 0
            }

            engine.resetHandler = { [weak self] in
                guard let self else { return }
                self.lastHapticTrigger = 0
                do {
                    try self.hapticEngine?.start()
                } catch {
                    self.hapticsAvailable = false
                }
            }

            try engine.start()
            hapticsAvailable = true
        } catch {
            hapticsAvailable = false
            hapticEngine = nil
        }
    }

    private func handleHaptics(for currentTime: Double) {
        guard hapticsAvailable, !isScrubbing, duration > 0 else { return }
        guard let player, player.timeControlStatus == .playing else { return }
        guard !hapticAmplitudeSamples.isEmpty else { return }

        let normalizedTime = max(min(currentTime / duration, 1), 0)
        let index = min(Int(normalizedTime * Double(hapticAmplitudeSamples.count - 1)), hapticAmplitudeSamples.count - 1)
        let amplitude = hapticAmplitudeSamples[index]

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHapticTrigger >= 0.08 else { return }
        lastHapticTrigger = now

        playHaptic(with: amplitude)
    }

    private func playHaptic(with amplitude: Double) {
        guard hapticsAvailable, amplitude > 0.02 else { return }

        let clamped = max(0.1, min(amplitude, 1.0))
        let sharpness = Float(min(clamped + 0.2, 0.95))
        let intensity = Float(clamped)

        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try hapticEngine?.makePlayer(with: pattern)
            try player?.start(atTime: 0)
        } catch {
            hapticsAvailable = false
        }
    }

    private func resetHapticsState() {
        lastHapticTrigger = 0
    }

    private func configureAudioSession() {
        guard !audioSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            audioSessionConfigured = false
        }
    }

    private func observePlayback(on player: AVPlayer, item: AVPlayerItem) {
        let interval = CMTime(seconds: 0.033, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = min(time.seconds, self.duration)
            if player.timeControlStatus == .playing {
                self.handleHaptics(for: self.currentTime)
            }
            if self.duration > 0, self.currentTime >= self.duration - 0.05 {
                self.didFinishPlaying = true
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.didFinishPlaying = true
            self.pause()
            self.currentTime = self.duration
            self.resetHapticsState()
        }
    }

    private func analyzeAudioForHaptics(from asset: AVAsset, targetSampleCount: Int = 360) {
        guard let track = asset.tracks(withMediaType: .audio).first else {
            DispatchQueue.main.async { [weak self] in
                self?.hapticAmplitudeSamples = []
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let reader = try AVAssetReader(asset: asset)
                let outputSettings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]

                let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                output.alwaysCopiesSampleData = false
                reader.add(output)

                guard reader.startReading() else {
                    DispatchQueue.main.async { [weak self] in
                        self?.hapticAmplitudeSamples = []
                    }
                    return
                }

                var rawSamples: [CGFloat] = []

                while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
                    guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else {
                        CMSampleBufferInvalidate(buffer)
                        continue
                    }

                    let length = CMBlockBufferGetDataLength(blockBuffer)
                    var data = Data(count: length)
                    data.withUnsafeMutableBytes { pointer in
                        if let address = pointer.baseAddress {
                            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: address)
                        }
                    }

                    data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
                        let int16Pointer = pointer.bindMemory(to: Int16.self)
                        for sampleIndex in 0..<(length / MemoryLayout<Int16>.size) {
                            let value = CGFloat(int16Pointer[sampleIndex]) / CGFloat(Int16.max)
                            rawSamples.append(abs(value))
                        }
                    }

                    CMSampleBufferInvalidate(buffer)
                }

                guard !rawSamples.isEmpty else {
                    DispatchQueue.main.async { [weak self] in
                        self?.hapticAmplitudeSamples = []
                    }
                    return
                }

                let chunkSize = max(1, rawSamples.count / targetSampleCount)
                var reducedSamples: [CGFloat] = []
                reducedSamples.reserveCapacity(targetSampleCount)

                var index = 0
                while index < rawSamples.count {
                    let end = min(index + chunkSize, rawSamples.count)
                    let chunk = rawSamples[index..<end]
                    let peak = chunk.max() ?? 0
                    reducedSamples.append(peak)
                    index += chunkSize
                }

                let maxVal = reducedSamples.max() ?? 1
                let normalized = maxVal > 0 ? reducedSamples.map { $0 / maxVal } : reducedSamples

                DispatchQueue.main.async { [weak self] in
                    self?.hapticAmplitudeSamples = normalized.map { Double($0) }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.hapticAmplitudeSamples = []
                }
            }
        }
    }
}

private enum PseudoWaveformGenerator {
    static func samples(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }

        return (0..<count).map { index in
            let progress = Double(index) / Double(max(count - 1, 1))
            let base = 0.55 + 0.35 * sin(progress * .pi * 2)
            let modulation = 0.2 * sin(progress * .pi * 6)
            let combined = max(0.05, min(base + modulation, 1.0))
            return CGFloat(combined)
        }
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

#Preview {
    ContentView()
}
