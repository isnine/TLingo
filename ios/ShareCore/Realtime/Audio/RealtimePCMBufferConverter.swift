#if os(macOS) || os(iOS)
    import AVFoundation
    import CoreMedia

    final class RealtimePCMBufferConverter {
        let targetFormat: AVAudioFormat

        private var converter: AVAudioConverter?
        private var converterInputFormat: AVAudioFormat?

        init?(
            sampleRate: Double = 16000,
            channels: AVAudioChannelCount = 1,
            commonFormat: AVAudioCommonFormat = .pcmFormatInt16
        ) {
            guard let targetFormat = AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            ) else {
                return nil
            }
            self.targetFormat = targetFormat
        }

        func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
            guard let sourceBuffer = sourcePCMBuffer(from: sampleBuffer) else { return nil }
            return pcmBuffer(from: sourceBuffer)
        }

        func pcmBuffer(from sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            if sourceBuffer.format == targetFormat {
                return sourceBuffer
            }

            if converter == nil || converterInputFormat != sourceBuffer.format {
                converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat)
                converterInputFormat = sourceBuffer.format
            }
            guard let converter else { return nil }

            let sampleRateRatio = targetFormat.sampleRate / sourceBuffer.format.sampleRate
            let frameCapacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * sampleRateRatio).rounded(.up)) + 1
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                return nil
            }

            var didProvideInput = false
            let inputBlock: AVAudioConverterInputBlock = { _, outputStatus in
                if didProvideInput {
                    outputStatus.pointee = .noDataNow
                    return nil
                }

                didProvideInput = true
                outputStatus.pointee = .haveData
                return sourceBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
            guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
                return nil
            }
            return outputBuffer
        }

        private func sourcePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0,
                  let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let sourceBuffer = AVAudioPCMBuffer(
                      pcmFormat: AVAudioFormat(cmAudioFormatDescription: formatDescription),
                      frameCapacity: AVAudioFrameCount(frameCount)
                  )
            else {
                return nil
            }

            sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frameCount),
                into: sourceBuffer.mutableAudioBufferList
            )
            guard status == noErr else { return nil }
            return sourceBuffer
        }
    }
#endif
