import AVFoundation
import MediaToolbox
import QuartzCore
import simd

struct MusicRhythmFrame {
    var bands = SIMD8<Float>(repeating: 0)
    var waveform = SIMD64<Float>(repeating: 0)
    var level: Float = 0
    var beat: Float = 0
    var time: Double = 0
    var received = false
}

/// Fixed-size filter bank. Its processing path allocates no buffers and never changes the audio.
struct MusicRhythmDetector {
    private var coefficient = SIMD8<Float>(repeating: 0)
    private var low = SIMD8<Float>(repeating: 0)
    private var energy = SIMD8<Float>(repeating: 0)
    private var total: Float = 0
    private var count = 0
    private var wave = SIMD64<Float>(repeating: 0)
    private var sampleStride = 32
    private var baseline: Float = 0.005
    private var previousBass: Float = 0
    private var lastBeat: Double = -10
    init(sampleRate: Double = 48000) {
        let frequencies: SIMD8<Float> = [70, 140, 280, 560, 1120, 2240, 4480, 8960]
        for i in 0..<8 { coefficient[i] = 1 - exp(-2 * .pi * min(frequencies[i], Float(sampleRate) * 0.4) / Float(sampleRate)) }
    }
    mutating func sample(_ value: Float) {
        guard value.isFinite else { return }
        if count % sampleStride == 0 { wave[min(63, count / sampleStride)] = value }
        low += coefficient * (SIMD8(repeating: value) - low)
        var previous: Float = 0
        for i in 0..<8 {
            let band = low[i] - previous; previous = low[i]
            energy[i] += band * band
        }
        total += value * value; count += 1
    }
    mutating func finish(time: Double) -> MusicRhythmFrame {
        guard count > 0 else { return MusicRhythmFrame() }
        var frame = MusicRhythmFrame(waveform: wave, time: time, received: true)
        for i in 0..<8 { frame.bands[i] = min(1, sqrt(energy[i] / Float(count)) * 6) }
        let bass = sqrt((energy[0] + energy[1]) / Float(count))
        let rise = max(0, bass - previousBass * 0.82)
        if bass > 0.006 && rise > max(0.003, baseline * 0.18) && time - lastBeat > 0.12 {
            frame.beat = min(1, rise / max(0.025, baseline * 1.6)); lastBeat = time
        }
        baseline += (bass - baseline) * 0.045; previousBass = bass
        frame.level = min(1, sqrt(total / Float(count)) * 3)
        energy = .zero; wave = .zero; total = 0; count = 0
        return frame
    }
    mutating func begin(frames: Int) { sampleStride = max(1, frames / 64) }
}

/// Non-blocking exchange between the audio callback and the 30Hz visualizer.
final class MusicRhythm: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var revision = 0
    private var frame = MusicRhythmFrame()
    private var beatTime: Double = -10
    private var beatValue: Float = 0
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return active }
        set { lock.lock(); active = newValue; if !newValue { frame = MusicRhythmFrame(); beatValue = 0 }; lock.unlock() }
    }
    @discardableResult func reset() -> Int {
        lock.lock(); defer { lock.unlock() }
        revision += 1; frame = MusicRhythmFrame(); beatValue = 0; return revision
    }
    fileprivate func accepts(_ ticket: Int) -> Bool {
        guard lock.try() else { return false }; defer { lock.unlock() }
        return active && ticket == revision
    }
    fileprivate func submit(_ next: MusicRhythmFrame, ticket: Int) {
        guard lock.try() else { return }; defer { lock.unlock() }
        guard active && ticket == revision else { return }
        frame = next
        if next.beat > 0 { beatTime = next.time; beatValue = next.beat }
    }
    func snapshot(at time: Double = CACurrentMediaTime()) -> MusicRhythmFrame {
        lock.lock(); defer { lock.unlock() }
        guard active, frame.received else { return MusicRhythmFrame() }
        var value = frame
        let age = max(0, time - frame.time)
        value.bands *= Float(exp(-max(0, age - 0.08) * 8))
        value.waveform *= Float(exp(-max(0, age - 0.08) * 8))
        value.level *= Float(exp(-max(0, age - 0.08) * 8))
        value.beat = beatValue * Float(exp(-max(0, time - beatTime) * 7))
        value.received = age < 1
        return value
    }
    @MainActor func makeMix(track: AVAssetTrack, ticket: Int) -> AVAudioMix? {
        let context = RhythmTapContext(owner: self, ticket: ticket)
        let storage = Unmanaged.passUnretained(context).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: storage,
            init: { _, client, out in
                if let client {
                    out.pointee = Unmanaged.passRetained(Unmanaged<RhythmTapContext>.fromOpaque(client).takeUnretainedValue()).toOpaque()
                }
            },
            finalize: { tap in Unmanaged<RhythmTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let state = Unmanaged<RhythmTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.format = format.pointee; state.detector = MusicRhythmDetector(sampleRate: format.pointee.mSampleRate)
            }, unprepare: nil,
            process: { tap, frames, _, buffers, countOut, flagsOut in
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, countOut)
                guard status == noErr else { countOut.pointee = 0; return }
                let state = Unmanaged<RhythmTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.consume(buffers, frames: Int(countOut.pointee), flags: flagsOut.pointee)
            })
        var tap: MTAudioProcessingTap?
        let status = withExtendedLifetime(context) { MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) }
        guard status == noErr, let tap else { return nil }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [input]
        return mix
    }
}

private final class RhythmTapContext {
    let owner: MusicRhythm
    let ticket: Int
    var format = AudioStreamBasicDescription()
    var detector = MusicRhythmDetector()
    init(owner: MusicRhythm, ticket: Int) { self.owner = owner; self.ticket = ticket }
    func consume(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, flags: MTAudioProcessingTapFlags) {
        guard frames > 0, owner.accepts(ticket), format.mFormatID == kAudioFormatLinearPCM else { return }
        if flags & kMTAudioProcessingTapFlag_StartOfStream != 0 { detector = MusicRhythmDetector(sampleRate: format.mSampleRate) }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let safeFrames = min(frames, Int(first.mDataByteSize) / max(1, Int(format.mBitsPerChannel / 8) * channels))
        detector.begin(frames: safeFrames)
        for index in 0..<safeFrames {
            let offset = index * channels
            let value: Float
            if floating && format.mBitsPerChannel == 32 { value = data.assumingMemoryBound(to: Float.self)[offset] }
            else if !floating && format.mBitsPerChannel == 16 { value = Float(data.assumingMemoryBound(to: Int16.self)[offset]) / 32768 }
            else { return }
            detector.sample(value)
        }
        owner.submit(detector.finish(time: CACurrentMediaTime()), ticket: ticket)
    }
}
