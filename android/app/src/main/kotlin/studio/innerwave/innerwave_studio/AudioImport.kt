package studio.innerwave.innerwave_studio

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import java.io.File
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

// Normalizes one selected mono/stereo audio stream into the editor's PCM file.
// All loops run on the method channel's serial background task queue.
internal object AudioImport {
    fun decode(input: String, output: String): Long {
        val extractor = MediaExtractor()
        val destination = File(output)
        val temporary = File.createTempFile("import-", ".pcm", destination.parentFile)
        try {
            extractor.setDataSource(input)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: error("This file has no readable audio track.")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val frames = temporary.outputStream().buffered(65536).use { sink ->
                val writer = StereoWriter(sink)
                if (format.getString(MediaFormat.KEY_MIME) == "audio/raw") {
                    writer.configure(format)
                    val hint = if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE))
                        format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 0
                    val packet = ByteBuffer.allocateDirect(maxOf(hint, 262144))
                    while (true) {
                        packet.clear()
                        val length = extractor.readSampleData(packet, 0)
                        if (length < 0) break
                        packet.position(0)
                        packet.limit(length)
                        writer.write(packet)
                        extractor.advance()
                    }
                } else {
                    decodeCompressed(extractor, format, writer)
                }
                writer.finish()
            }
            require(frames > 0 && temporary.length() == frames * 4) { "Incomplete or empty audio." }
            check(!destination.exists() && temporary.renameTo(destination)) { "Unable to save imported audio." }
            return frames
        } finally {
            extractor.release()
            temporary.delete()
        }
    }

    private fun decodeCompressed(extractor: MediaExtractor, format: MediaFormat, writer: StereoWriter) {
        val codec = MediaCodec.createDecoderByType(requireNotNull(format.getString(MediaFormat.KEY_MIME)))
        try {
            codec.configure(format, null, null, 0)
            codec.start()
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var activeAt = SystemClock.elapsedRealtime()
            while (true) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10000)
                    if (i >= 0) {
                        val packet = requireNotNull(codec.getInputBuffer(i))
                        val length = extractor.readSampleData(packet, 0)
                        if (length < 0) {
                            codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(i, 0, length, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                        activeAt = SystemClock.elapsedRealtime()
                    }
                }
                val i = codec.dequeueOutputBuffer(info, 10000)
                when {
                    i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> writer.configure(codec.outputFormat)
                    i >= 0 -> {
                        try {
                            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                val packet = requireNotNull(codec.getOutputBuffer(i))
                                packet.limit(info.offset + info.size)
                                packet.position(info.offset)
                                writer.write(packet)
                            }
                        } finally {
                            codec.releaseOutputBuffer(i, false)
                        }
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                        activeAt = SystemClock.elapsedRealtime()
                    }
                }
                check(SystemClock.elapsedRealtime() - activeAt < 30000) { "The audio decoder stopped responding." }
            }
        } finally {
            codec.release()
        }
    }
}

private class StereoWriter(private val sink: OutputStream) {
    private var rate = 0
    private var channels = 0
    private var encoding = AudioFormat.ENCODING_PCM_16BIT
    private var bytesPerSample = 2
    private var sourceFrames = 0L
    private var outputFrames = 0L
    private var lastL = 0
    private var lastR = 0
    private val packed = ByteBuffer.allocate(32768).order(ByteOrder.LITTLE_ENDIAN)

    fun configure(format: MediaFormat) {
        val newRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        require(newRate > 0 && (sourceFrames == 0L || rate == newRate)) { "Unsupported audio sample rate change." }
        rate = newRate
        channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        require(channels in 1..2) { "Please import a mono or stereo version of this file." }
        encoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING))
            format.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
        bytesPerSample = when (encoding) {
            AudioFormat.ENCODING_PCM_8BIT -> 1
            AudioFormat.ENCODING_PCM_16BIT -> 2
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
            AudioFormat.ENCODING_PCM_32BIT, AudioFormat.ENCODING_PCM_FLOAT -> 4
            else -> error("Unsupported PCM encoding.")
        }
    }

    private fun sample(b: ByteBuffer): Int = when (encoding) {
        AudioFormat.ENCODING_PCM_8BIT -> ((b.get().toInt() and 255) - 128) shl 8
        AudioFormat.ENCODING_PCM_16BIT -> b.short.toInt()
        AudioFormat.ENCODING_PCM_FLOAT -> (b.float.coerceIn(-1f, 1f) * 32767).roundToInt()
        AudioFormat.ENCODING_PCM_32BIT -> b.int shr 16
        else -> { b.get(); (b.get().toInt() and 255) or (b.get().toInt() shl 8) }
    }

    fun write(packet: ByteBuffer) {
        require(rate > 0 && packet.remaining() % (channels * bytesPerSample) == 0) { "Invalid PCM frame." }
        packet.order(ByteOrder.LITTLE_ENDIAN)
        while (packet.hasRemaining()) {
            val left = sample(packet)
            val right = if (channels == 2) sample(packet) else left
            // An integer clock keeps the two channels phase-locked across decoder buffers.
            val now = sourceFrames * 44100L
            while (outputFrames * rate <= now) {
                val fraction = 1.0 - (now - outputFrames * rate) / 44100.0
                emit(lastL + ((left - lastL) * fraction).roundToInt(),
                     lastR + ((right - lastR) * fraction).roundToInt())
            }
            lastL = left
            lastR = right
            sourceFrames++
        }
    }

    private fun emit(left: Int, right: Int) {
        packed.putShort(left.toShort())
        packed.putShort(right.toShort())
        outputFrames++
        if (!packed.hasRemaining()) flush()
    }

    private fun flush() {
        sink.write(packed.array(), 0, packed.position())
        packed.clear()
    }

    fun finish(): Long {
        while (outputFrames * rate < sourceFrames * 44100L) emit(lastL, lastR)
        flush()
        return outputFrames
    }
}
