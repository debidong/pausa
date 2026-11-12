#!/usr/bin/env swift
// Regenerates App/sounds/break-{long,short}-{start,end}.caf (48 kHz 16-bit stereo CAF).
// Acoustic Harp & Nylon Guitar waveguide synthesis + Apple AVAudioUnitReverb offline mastering.
//
// Usage: swift scripts/make-chimes.swift [output-dir]

import AVFoundation
import Foundation

let sampleRate: Double = 48_000.0
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/sounds"
let outDir = URL(fileURLWithPath: outPath, isDirectory: true)

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func nextDouble() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53) * 2.0 - 1.0
    }
}

func midiToHz(_ midi: Double) -> Double {
    440.0 * pow(2.0, (midi - 69.0) / 12.0)
}

// Extended Karplus-Strong nylon/concert-harp string waveguide with fractional allpass tuning
// and natural wooden soundboard bloom.
func addPluckedString(
    left: inout [Float],
    right: inout [Float],
    midi: Double,
    startSec: Double,
    velocity: Double,
    pan: Double,
    brightness: Double = 0.42,
    damping: Double = 0.9968,
    seed: UInt64
) {
    let totalFrames = left.count
    let startFrame = Int(startSec * sampleRate)
    guard startFrame < totalFrames else { return }

    let freq = midiToHz(midi)
    let exactPeriod = sampleRate / freq
    let delayLen = max(4, Int(floor(exactPeriod - 0.5)))
    let frac = exactPeriod - 0.5 - Double(delayLen)
    let allpassC = (1.0 - frac) / (1.0 + frac)

    var rng = SplitMix64(seed: seed)
    var ring = [Double](repeating: 0.0, count: delayLen)

    var lp = 0.0
    let pickPos = max(2, Int(Double(delayLen) * 0.23))
    var rawExcite = [Double](repeating: 0.0, count: delayLen)
    for i in 0..<delayLen {
        let n = rng.nextDouble()
        lp = lp * (1.0 - brightness) + n * brightness
        let phase = Double(i) / Double(delayLen)
        let warmFundamental = sin(2.0 * .pi * phase) * 0.55 + sin(4.0 * .pi * phase) * 0.20
        rawExcite[i] = lp * 0.65 + warmFundamental
    }
    for i in 0..<delayLen {
        let combIdx = (i - pickPos + delayLen) % delayLen
        let window = sin(.pi * Double(i) / Double(delayLen))
        ring[i] = (rawExcite[i] - 0.45 * rawExcite[combIdx]) * (0.55 + 0.45 * window)
    }

    let renderFrames = min(totalFrames - startFrame, Int(4.2 * sampleRate))
    var idx = 0
    var prevOut = 0.0
    var apPrevX = 0.0
    var apPrevY = 0.0

    let loopGain = min(0.9988, damping - (freq / 40_000.0))
    let loopTone = min(0.72, max(0.26, 0.34 + (350.0 / (freq + 300.0)) * 0.28))

    let panAngle = (pan + 1.0) * 0.25 * .pi
    let gainL = cos(panAngle) * velocity
    let gainR = sin(panAngle) * velocity
    let haasSamples = pan >= 0 ? 11 : -11

    for n in 0..<renderFrames {
        let nextIdx = (idx + 1) % delayLen
        let avg = (1.0 - loopTone) * ring[idx] + loopTone * ring[nextIdx]
        prevOut = 0.85 * avg + 0.15 * prevOut
        let apY = allpassC * prevOut + apPrevX - allpassC * apPrevY
        apPrevX = prevOut
        apPrevY = apY

        ring[idx] = apY * loopGain
        idx = nextIdx

        let t = Double(n) / sampleRate
        let attack = min(1.0, t / 0.0025)
        let bodyBloom = 0.16 * sin(2.0 * .pi * freq * t) * exp(-t / 0.65) * (1.0 - exp(-t / 0.015))
        let sample = (apY * 0.88 + bodyBloom) * attack

        let iL = startFrame + n + max(0, haasSamples)
        let iR = startFrame + n + max(0, -haasSamples)
        if iL < totalFrames { left[iL] += Float(sample * gainL) }
        if iR < totalFrames { right[iR] += Float(sample * gainR) }
    }
}

func masterAndSaveCAF(
    name: String,
    left: [Float],
    right: [Float],
    reverbPreset: AVAudioUnitReverbPreset,
    wetDryMix: Float,
    targetPeakDB: Double
) throws {
    let frameCount = AVAudioFrameCount(left.count)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let dryBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    dryBuffer.frameLength = frameCount
    memcpy(dryBuffer.floatChannelData![0], left, left.count * MemoryLayout<Float>.size)
    memcpy(dryBuffer.floatChannelData![1], right, right.count * MemoryLayout<Float>.size)

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 2)
    eq.bands[0].filterType = .highPass
    eq.bands[0].frequency = 85.0
    eq.bands[0].bypass = false

    eq.bands[1].filterType = .lowPass
    eq.bands[1].frequency = 6800.0
    eq.bands[1].bypass = false

    let reverb = AVAudioUnitReverb()
    reverb.loadFactoryPreset(reverbPreset)
    reverb.wetDryMix = wetDryMix

    engine.attach(player)
    engine.attach(eq)
    engine.attach(reverb)

    engine.connect(player, to: eq, format: format)
    engine.connect(eq, to: reverb, format: format)
    engine.connect(reverb, to: engine.mainMixerNode, format: format)

    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    try engine.start()

    player.scheduleBuffer(dryBuffer, at: nil, options: [], completionHandler: nil)
    player.play()

    var outL = [Float](repeating: 0, count: left.count)
    var outR = [Float](repeating: 0, count: right.count)
    let renderBuf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!

    var offset = 0
    while offset < left.count {
        let framesToRender = min(4096, left.count - offset)
        let status = try engine.renderOffline(AVAudioFrameCount(framesToRender), to: renderBuf)
        if status == .success {
            let rL = renderBuf.floatChannelData![0]
            let rR = renderBuf.floatChannelData![1]
            for i in 0..<Int(renderBuf.frameLength) {
                outL[offset + i] = rL[i]
                outR[offset + i] = rR[i]
            }
            offset += Int(renderBuf.frameLength)
        } else {
            break
        }
    }
    engine.stop()

    let fadeFrames = min(left.count / 4, Int(0.45 * sampleRate))
    let fadeStart = left.count - fadeFrames
    for i in fadeStart..<left.count {
        let progress = Double(i - fadeStart) / Double(fadeFrames)
        let gain = Float(0.5 * (1.0 + cos(.pi * progress)))
        outL[i] *= gain
        outR[i] *= gain
    }

    var peak: Float = 0.0001
    for i in 0..<outL.count {
        peak = max(peak, abs(outL[i]), abs(outR[i]))
    }
    let targetAmp = Float(pow(10.0, targetPeakDB / 20.0))
    let scale = targetAmp / peak
    for i in 0..<outL.count {
        outL[i] *= scale
        outR[i] *= scale
    }

    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let outURL = outDir.appendingPathComponent("\(name).caf")
    try? FileManager.default.removeItem(at: outURL)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let outFile = try AVAudioFile(forWriting: outURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let finalBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    finalBuf.frameLength = frameCount
    memcpy(finalBuf.floatChannelData![0], outL, outL.count * MemoryLayout<Float>.size)
    memcpy(finalBuf.floatChannelData![1], outR, outR.count * MemoryLayout<Float>.size)
    try outFile.write(from: finalBuf)
    print("Wrote \(outURL.path) (\(String(format: "%.2f", Double(left.count) / sampleRate))s)")
}

// 1. Long Break Start (4.20s): Warm Fmaj9 open harp arpeggio (F3 -> C4 -> G4 -> A4)
do {
    let n = Int(4.2 * sampleRate)
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    addPluckedString(left: &l, right: &r, midi: 53, startSec: 0.04, velocity: 0.72, pan: -0.22, brightness: 0.36, damping: 0.9975, seed: 101)
    addPluckedString(left: &l, right: &r, midi: 60, startSec: 0.28, velocity: 0.66, pan: -0.06, brightness: 0.40, damping: 0.9972, seed: 102)
    addPluckedString(left: &l, right: &r, midi: 67, startSec: 0.55, velocity: 0.62, pan:  0.12, brightness: 0.42, damping: 0.9968, seed: 103)
    addPluckedString(left: &l, right: &r, midi: 69, startSec: 0.88, velocity: 0.70, pan:  0.24, brightness: 0.38, damping: 0.9972, seed: 104)
    try masterAndSaveCAF(name: "break-long-start", left: l, right: r, reverbPreset: .mediumHall, wetDryMix: 21, targetPeakDB: -4.5)
}

// 2. Long Break End (3.20s): Crisp Csus2 fifths lift (C4 -> G4 -> D5)
do {
    let n = Int(3.2 * sampleRate)
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    addPluckedString(left: &l, right: &r, midi: 60, startSec: 0.04, velocity: 0.68, pan: -0.18, brightness: 0.42, damping: 0.9968, seed: 201)
    addPluckedString(left: &l, right: &r, midi: 67, startSec: 0.21, velocity: 0.68, pan:  0.02, brightness: 0.44, damping: 0.9966, seed: 202)
    addPluckedString(left: &l, right: &r, midi: 74, startSec: 0.40, velocity: 0.72, pan:  0.20, brightness: 0.40, damping: 0.9965, seed: 203)
    try masterAndSaveCAF(name: "break-long-end", left: l, right: r, reverbPreset: .mediumHall, wetDryMix: 20, targetPeakDB: -4.5)
}

// 3. Short Break Start (2.50s): Gentle 2-string nylon sigh (A4 -> F4, "soften your gaze")
do {
    let n = Int(2.5 * sampleRate)
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    addPluckedString(left: &l, right: &r, midi: 69, startSec: 0.04, velocity: 0.62, pan:  0.14, brightness: 0.36, damping: 0.9964, seed: 301)
    addPluckedString(left: &l, right: &r, midi: 65, startSec: 0.27, velocity: 0.68, pan: -0.14, brightness: 0.35, damping: 0.9968, seed: 302)
    try masterAndSaveCAF(name: "break-short-start", left: l, right: r, reverbPreset: .mediumHall, wetDryMix: 19, targetPeakDB: -5.8)
}

// 4. Short Break End (2.20s): Light 2-string fifth lift (F4 -> C5, "back to flow")
do {
    let n = Int(2.2 * sampleRate)
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    addPluckedString(left: &l, right: &r, midi: 65, startSec: 0.04, velocity: 0.64, pan: -0.14, brightness: 0.40, damping: 0.9962, seed: 401)
    addPluckedString(left: &l, right: &r, midi: 72, startSec: 0.22, velocity: 0.68, pan:  0.16, brightness: 0.40, damping: 0.9960, seed: 402)
    try masterAndSaveCAF(name: "break-short-end", left: l, right: r, reverbPreset: .mediumHall, wetDryMix: 18, targetPeakDB: -5.8)
}
