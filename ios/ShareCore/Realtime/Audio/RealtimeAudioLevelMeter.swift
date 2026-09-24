#if os(macOS) || os(iOS)
    import AVFoundation
    import CoreMedia
    import Foundation

    /// Computes the RMS audio level (in dBFS) for the PCM samples carried by `sampleBuffer`.
    /// Shared by `RealtimeSystemAudioCapture` and `RealtimeMicrophoneAudioCapture` so both
    /// capture sources report on the same scale.
    func realtimeAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )

        guard listSize > 0 else { return nil }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }

        let audioBufferList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let isFloat = streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var squareSum: Double = 0
        var sampleCount = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }

            if isFloat {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for index in 0 ..< count {
                    let sample = Double(samples[index])
                    squareSum += sample * sample
                }
                sampleCount += count
            } else {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0 ..< count {
                    let sample = Double(samples[index]) / Double(Int16.max)
                    squareSum += sample * sample
                }
                sampleCount += count
            }
        }

        guard sampleCount > 0 else { return nil }
        let rms = sqrt(squareSum / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return Float(decibels)
    }

    func realtimeAudioLevel(from pcmBuffer: AVAudioPCMBuffer) -> Float? {
        let frameLength = Int(pcmBuffer.frameLength)
        guard frameLength > 0 else { return nil }

        var squareSum: Double = 0
        var sampleCount = 0

        if let floatChannel = pcmBuffer.floatChannelData?.pointee {
            for index in 0 ..< frameLength {
                let sample = Double(floatChannel[index])
                squareSum += sample * sample
            }
            sampleCount = frameLength
        } else if let int16Channel = pcmBuffer.int16ChannelData?.pointee {
            for index in 0 ..< frameLength {
                let sample = Double(int16Channel[index]) / Double(Int16.max)
                squareSum += sample * sample
            }
            sampleCount = frameLength
        }

        guard sampleCount > 0 else { return nil }
        let rms = sqrt(squareSum / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return Float(decibels)
    }
#endif
