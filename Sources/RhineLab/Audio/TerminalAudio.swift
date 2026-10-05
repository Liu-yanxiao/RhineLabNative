import AVFoundation
import AudioToolbox
import Foundation
import QuartzCore

/// Interface sounds (web `audio.ts` → `Sound`).
enum Sound: Hashable {
    case pageOpen, pageClose, uiTick, brand, textReveal, key, tick, column, open, confirm, back, scan, welcome, array, inspect, explode, assemble
}

enum SoundScene { case boot, archive, detail, viewer }

struct AudioPreferences: Equatable {
    var sound = true
    var music = true
    var soundVolume: Float = 0.55
    var musicVolume: Float = 0.5
}

/// Interface sounds and the three-stem "Observatory" score, ported from the web version's
/// `audio.ts`. Effects are synthesised into PCM buffers from the same recipes; the stems loop
/// gaplessly from memory and are mixed per scene.
final class TerminalAudio {
    static let stems = ["atmosphere", "motif", "pulse"]
    static let loopFrames: AVAudioFramePosition = 2_560_000     // 160/3 s at 48 kHz
    /// Original-video seconds at which the opening plays its cues (`BOOT_CUES`).
    static let bootCues: [(time: Double, sound: Sound)] = [
        (9.16, .brand), (11.84, .confirm), (19.48, .scan), (21.84, .confirm), (22.76, .welcome),
        (23.52, .textReveal), (25.04, .textReveal), (26.92, .array), (30.68, .open), (34.3, .inspect),
    ]

    private let engine = AVAudioEngine()
    private let effects = AVAudioMixerNode()
    private let musicBus = AVAudioMixerNode()
    private let duck = AVAudioMixerNode()
    private let premaster = AVAudioMixerNode()
    private let limiter: AVAudioUnitEffect
    private let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private var stemPlayers: [AVAudioPlayerNode] = []
    private var stemFiles: [AVAudioFile] = []
    private var stemBuffers: [AVAudioPCMBuffer] = []
    private var voices: [AVAudioPlayerNode] = []
    private var busy: Set<ObjectIdentifier> = []
    private let voiceLock = NSLock()
    private let bank = SoundBank()

    private(set) var prefs = AudioPreferences()
    private var scene: SoundScene = .boot
    private var lastSound: [Sound: Double] = [:]
    private var musicPlaying = false
    private var musicOffset: AVAudioFramePosition = 0
    private var loading = false
    private var loaded = false
    private var bootMix = -1

    // Volume ramps evaluated by a timer (WebAudio linearRampToValueAtTime stand-in).
    private struct Ramp {
        var from: Float, to: Float, start: Double, duration: Double
        var next: (to: Float, duration: Double)? = nil
        func value(_ now: Double) -> Float {
            duration <= 0 ? to : from + (to - from) * Float(max(0, min(1, (now - start) / duration)))
        }
    }
    private var ramps: [String: Ramp] = [:]
    private var timer: DispatchSourceTimer?
    private let rampQueue = DispatchQueue(label: "RhineLab.audio.ramps")

    init() {
        let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        limiter = AVAudioUnitEffect(audioComponentDescription: description)
        for node in [effects, musicBus, duck, premaster, limiter] { engine.attach(node) }
        for _ in Self.stems {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: musicBus, format: stereo)
            player.volume = 0
            stemPlayers.append(player)
        }
        for _ in 0..<10 {
            let voice = AVAudioPlayerNode()
            engine.attach(voice)
            engine.connect(voice, to: effects, format: mono)
            voices.append(voice)
        }
        engine.connect(musicBus, to: duck, format: stereo)
        engine.connect(duck, to: premaster, format: stereo)
        engine.connect(effects, to: premaster, format: stereo)
        engine.connect(premaster, to: limiter, format: stereo)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereo)
        engine.mainMixerNode.outputVolume = 0.8
        // Gentle limiter: threshold −8 dB, 8 dB knee, 3 ms attack, 180 ms release.
        let unit = limiter.audioUnit
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -8, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 8, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.003, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.18, 0)
        effects.outputVolume = 0
        musicBus.outputVolume = 0
        duck.outputVolume = 1
    }

    // MARK: Preferences and lifecycle

    func configure(_ next: AudioPreferences) {
        prefs = next
        if engine.isRunning {
            ramp("effects", to: prefs.sound ? prefs.soundVolume : 0, over: 0.05)
            ramp("music", to: prefs.music ? prefs.musicVolume : 0, over: 0.2)
        }
        if !prefs.music { stopMusic() }
        if !prefs.sound && !prefs.music { suspend() } else { activate() }
    }

    private func activate() {
        guard prefs.sound || prefs.music else { return }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return }
            effects.outputVolume = prefs.sound ? prefs.soundVolume : 0
            musicBus.outputVolume = prefs.music ? prefs.musicVolume : 0
            startTimer()
            mixScene(over: 1.1)
        }
        if prefs.music { loadMusic { [weak self] in self?.startMusic() } }
    }

    private func suspend() {
        stopMusic()
        lastSound.removeAll()
        if engine.isRunning { engine.pause() }
        timer?.cancel(); timer = nil
    }

    private func loadMusic(then: @escaping () -> Void) {
        if loaded { then(); return }
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var files: [AVAudioFile] = [], buffers: [AVAudioPCMBuffer] = []
            for name in Self.stems {
                guard let url = Bundle.main.url(forResource: name, withExtension: "m4a"),
                      let file = try? AVAudioFile(forReading: url),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buffer)) != nil else { continue }
                files.append(file); buffers.append(buffer)
            }
            DispatchQueue.main.async {
                self.loading = false
                guard files.count == Self.stems.count else { return }
                self.stemFiles = files; self.stemBuffers = buffers; self.loaded = true
                then()
            }
        }
    }

    private func startMusic() {
        guard engine.isRunning, loaded, !musicPlaying, prefs.music else { return }
        musicPlaying = true
        for (i, player) in stemPlayers.enumerated() {
            let file = stemFiles[i], buffer = stemBuffers[i]
            let offset = musicOffset % min(Self.loopFrames, file.length)
            if offset > 0 {
                player.scheduleSegment(file, startingFrame: offset, frameCount: AVAudioFrameCount(file.length - offset), at: nil)
            }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
        }
        musicBus.outputVolume = 0
        ramp("music", to: prefs.musicVolume, over: 1.2)
    }

    private func stopMusic() {
        guard musicPlaying else { return }
        musicPlaying = false
        if let node = stemPlayers.first, let last = node.lastRenderTime, let time = node.playerTime(forNodeTime: last) {
            musicOffset = (musicOffset + max(0, time.sampleTime)) % Self.loopFrames
        }
        ramp("music", to: 0, over: 0.06)
        let players = stemPlayers
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { for p in players { p.stop() } }
    }

    // MARK: Scenes and ducking

    /// The opening replays: forget cue progress and interrupt nothing else.
    func restartBoot() {
        lastSound.removeAll()
        bootMix = -1
    }

    func setScene(_ next: SoundScene) {
        guard scene != next else { return }
        scene = next
        bootMix = -1
        lastSound.removeAll()
        mixScene(over: 1.1)
    }

    private static let sceneMix: [SoundScene: [Float]] = [
        .boot: [0.48, 0.32, 0.18], .archive: [0.9, 0.72, 0.65], .detail: [0.72, 0.36, 0.12], .viewer: [0.8, 0.24, 0.28],
    ]

    private func mixScene(over seconds: Double) {
        guard let gains = Self.sceneMix[scene] else { return }
        for (i, g) in gains.enumerated() { ramp("stem\(i)", to: g, over: seconds) }
    }

    /// Opening mix follows the original video's phases; `time` is app time (video − 5 s).
    func updateBoot(appTime: Double, previous: Double?) {
        let time = appTime + 5
        let phase = time < 22.76 ? 0 : time < 26.92 ? 1 : time < 34.3 ? 2 : 3
        if phase != bootMix, engine.isRunning {
            bootMix = phase
            let gains: [[Float]] = [[0.48, 0.32, 0.18], [0.68, 0.55, 0.32], [0.9, 0.72, 0.65], [0.72, 0.36, 0.12]]
            for (i, g) in gains[phase].enumerated() { ramp("stem\(i)", to: g, over: 0.9) }
        }
        guard let previous, time >= previous, time - previous <= 0.3 else { return }
        for cue in Self.bootCues where cue.time > previous && cue.time <= time { play(cue.sound) }
    }

    func play(_ sound: Sound, pan: Float = 0) {
        guard prefs.sound, engine.isRunning else { return }
        let now = CACurrentMediaTime()
        let interval = sound == .key ? 0.024 : (sound == .tick || sound == .column) ? 0.055 : 0.12
        if now - (lastSound[sound] ?? -.infinity) < interval { return }
        lastSound[sound] = now
        guard let buffer = bank.buffer(for: sound), let voice = freeVoice() else { return }
        voice.pan = max(-0.65, min(0.65, pan))
        voice.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.voiceLock.lock(); self?.busy.remove(ObjectIdentifier(voice)); self?.voiceLock.unlock()
        }
        voice.play()
        if [.open, .brand, .welcome, .array, .explode, .assemble].contains(sound) {
            ramp("duck", to: 0.65, over: 0.035, then: (1, 0.9))
        }
    }

    private func freeVoice() -> AVAudioPlayerNode? {
        voiceLock.lock(); defer { voiceLock.unlock() }
        guard let voice = voices.first(where: { !busy.contains(ObjectIdentifier($0)) }) else { return nil }
        busy.insert(ObjectIdentifier(voice))
        return voice
    }

    // MARK: Ramps

    private func ramp(_ key: String, to: Float, over seconds: Double, then next: (to: Float, duration: Double)? = nil) {
        rampQueue.async { [self] in
            let now = CACurrentMediaTime()
            let from = ramps[key]?.value(now) ?? current(key)
            ramps[key] = Ramp(from: from, to: to, start: now, duration: seconds, next: next)
        }
    }

    private func current(_ key: String) -> Float {
        switch key {
        case "effects": return effects.outputVolume
        case "music": return musicBus.outputVolume
        case "duck": return duck.outputVolume
        default:
            if key.hasPrefix("stem"), let i = Int(key.dropFirst(4)), i < stemPlayers.count { return stemPlayers[i].volume }
            return 0
        }
    }

    private func apply(_ key: String, _ value: Float) {
        switch key {
        case "effects": effects.outputVolume = value
        case "music": musicBus.outputVolume = value
        case "duck": duck.outputVolume = value
        default:
            if key.hasPrefix("stem"), let i = Int(key.dropFirst(4)), i < stemPlayers.count { stemPlayers[i].volume = value }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: rampQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            for (key, ramp) in ramps {
                apply(key, ramp.value(now))
                if now >= ramp.start + ramp.duration {
                    if let next = ramp.next {
                        ramps[key] = Ramp(from: ramp.to, to: next.to, start: now, duration: next.duration)
                    } else {
                        ramps[key] = nil
                    }
                }
            }
        }
        t.resume()
        timer = t
    }
}

/// Renders each interface sound once, from the web version's oscillator / noise recipes.
final class SoundBank {
    private let sampleRate = 48000.0
    private var cache: [Sound: AVAudioPCMBuffer] = [:]
    private var typing: [AVAudioPCMBuffer] = []
    private var nextTyping = 0
    private lazy var noise: [Float] = {
        var seed: UInt32 = 773
        return (0..<Int(sampleRate * 2)).map { _ in
            seed = seed &* 1664525 &+ 1013904223
            return Float(Double(seed) / 2147483648 - 1)
        }
    }()

    func buffer(for sound: Sound) -> AVAudioPCMBuffer? {
        if sound == .key {
            if typing.isEmpty { typing = loadTyping() }
            guard !typing.isEmpty else { return nil }
            defer { nextTyping += 1 }
            return typing[nextTyping % typing.count]
        }
        if let hit = cache[sound] { return hit }
        let rendered = render(sound)
        cache[sound] = rendered
        return rendered
    }

    /// The three original-video keystrokes (38 ms each), at the reference gain of 0.2.
    private func loadTyping() -> [AVAudioPCMBuffer] {
        (1...3).compactMap { i -> AVAudioPCMBuffer? in
            guard let url = Bundle.main.url(forResource: "typing-\(i)", withExtension: "wav"),
                  let file = try? AVAudioFile(forReading: url),
                  let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: raw)) != nil,
                  let data = raw.floatChannelData else { return nil }
            let n = Int(raw.frameLength)
            return make((0..<n).map { data[0][$0] * 0.2 })
        }
    }

    private func make(_ samples: [Float]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let out = buffer.floatChannelData { for i in 0..<samples.count { out[0][i] = samples[i] } }
        return buffer
    }

    private func render(_ sound: Sound) -> AVAudioPCMBuffer? {
        let sr = sampleRate
        var out = [Float](repeating: 0, count: Int(sr * 0.5))
        var end = 0.0

        // Gain envelope: short linear attack, exponential decay to −100 dB, 12 ms release.
        func envelope(_ t: Double, _ gain: Double, _ attack: Double, _ duration: Double) -> Double {
            let attackEnd = min(attack, duration * 0.3)
            if t < attackEnd { return attackEnd > 0 ? gain * t / attackEnd : gain }
            if t < duration { return gain * pow(1e-5 / gain, (t - attackEnd) / max(1e-6, duration - attackEnd)) }
            return max(0, 1e-5 * (1 - (t - duration) / 0.012))
        }
        func reserve(_ samples: Int) { if out.count < samples { out += [Float](repeating: 0, count: samples - out.count) } }

        func tone(_ f: Double, _ to: Double, _ gain: Double, _ duration: Double, _ delay: Double = 0, _ attack: Double = 0.006) {
            let s0 = Int(delay * sr), n = Int((duration + 0.015) * sr)
            reserve(s0 + n)
            var phase = 0.0
            for k in 0..<n {
                let t = Double(k) / sr
                let freq = f * pow(to / f, min(1, t / duration))
                phase += 2 * .pi * freq / sr
                out[s0 + k] += Float(sin(phase) * envelope(t, gain, attack, duration))
            }
            end = max(end, delay + duration + 0.015)
        }
        func air(_ f: Double, _ to: Double, _ gain: Double, _ duration: Double, _ delay: Double = 0, _ attack: Double = 0.008) {
            let s0 = Int(delay * sr), n = Int((duration + 0.015) * sr)
            reserve(s0 + n)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for k in 0..<n {
                let t = Double(k) / sr
                let fc = f * pow(to / f, min(1, t / duration))
                let w = 2 * .pi * fc / sr, alpha = sin(w) / (2 * 0.8)
                let a0 = 1 + alpha, a1 = -2 * cos(w), a2 = 1 - alpha
                let x = Double(noise[(s0 + k) % noise.count])
                let y = (alpha * x - alpha * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = x; y2 = y1; y1 = y
                out[s0 + k] += Float(y * envelope(t, gain, attack, duration))
            }
            end = max(end, delay + duration + 0.015)
        }
        // A thin glass plate: a fast contact transient excites unequal modes; upper modes fade first.
        func glass(_ fundamental: Double, _ gain: Double, _ decay: Double, _ delay: Double = 0) {
            let modes: [(Double, Double, Double)] = [(1, 1, 1), (1.47, 0.39, 0.66), (2.09, 0.21, 0.4), (2.73, 0.095, 0.25), (3.86, 0.035, 0.15)]
            for (ratio, amplitude, damping) in modes {
                let frequency = fundamental * ratio
                if frequency > min(8500, sr * 0.42) { continue }
                tone(frequency, frequency, gain * amplitude, decay * damping, delay, 0.0012)
            }
            air(4800, 3600, gain * 0.24, 0.013, delay, 0.0008)
        }

        switch sound {
        case .pageOpen:
            air(700, 1800, 0.065, 0.18, 0, 0.025); tone(360, 480, 0.032, 0.16, 0, 0.014); tone(960, 960, 0.009, 0.075, 0.06, 0.01)
        case .pageClose:
            air(1300, 600, 0.05, 0.13, 0, 0.014); tone(420, 280, 0.027, 0.13, 0, 0.01)
        case .uiTick:
            air(1500, 1200, 0.042, 0.036, 0, 0.003); tone(820, 820, 0.022, 0.052, 0, 0.003)
        case .brand:
            tone(146.83, 146.83, 0.039, 0.72, 0, 0.08); tone(293.66, 293.66, 0.03, 0.62, 0.07, 0.07)
            tone(440, 440, 0.022, 0.54, 0.17, 0.055); air(420, 1750, 0.036, 0.7, 0, 0.13)
        case .textReveal:
            air(2100, 1300, 0.033, 0.064, 0, 0.005); tone(1050, 1050, 0.012, 0.06, 0, 0.005)
        case .key:
            return nil
        case .tick:
            glass(1680, 0.064, 0.24)
        case .column:
            glass(1280, 0.065, 0.32); glass(2050, 0.016, 0.18, 0.045)
        case .open:
            glass(1150, 0.071, 0.58); glass(2180, 0.025, 0.36, 0.16); air(3100, 4400, 0.014, 0.25, 0.035, 0.025)
        case .confirm:
            tone(640, 640, 0.039, 0.095, 0, 0.008); tone(960, 960, 0.026, 0.15, 0.095, 0.009)
        case .back:
            glass(1120, 0.066, 0.22); tone(560, 560, 0.012, 0.1, 0.025, 0.002)
        case .scan:
            air(1800, 3400, 0.025, 0.8, 0, 0.12)
            for i in 0..<4 { tone(760, 760, 0.025, 0.064, Double(i) * 0.19 + 0.15, 0.007) }
        case .welcome:
            for (i, f) in [293.66, 440, 659.25, 739.99].enumerated() { tone(f, f, 0.034, 1.6, Double(i) * 0.095, 0.05) }
            air(600, 1800, 0.065, 0.9, 0, 0.15)
        case .array:
            air(1600, 3300, 0.025, 0.8, 0, 0.12)
            for i in 0..<5 { glass(1180 + Double(i) * 170, 0.043 - Double(i) * 0.005, 0.31, 0.05 + Double(i) * 0.105) }
        case .inspect:
            tone(1120, 1120, 0.026, 0.055, 0, 0.005); tone(1120, 1120, 0.018, 0.055, 0.11, 0.005)
        case .explode:
            for (i, f) in [1220.0, 1680, 2260].enumerated() { glass(f, 0.054 - Double(i) * 0.01, 0.4 - Double(i) * 0.055, Double(i) * 0.115) }
        case .assemble:
            for (i, f) in [2260.0, 1680, 1220].enumerated() { glass(f, 0.035 + Double(i) * 0.008, 0.2, Double(i) * 0.095) }
        }
        let frames = min(out.count, Int(end * sr) + 1)
        return make(Array(out.prefix(frames)))
    }
}
