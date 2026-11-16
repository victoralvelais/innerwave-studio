package studio.innerwave.innerwave_studio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One stereo output clock for every clip. Audio focus belongs to the Dart audio session. */
internal class StereoPreview {
    private var track: AudioTrack? = null
    private var accepted = 0L
    private var stride = 4

    @Synchronized fun start(pcm: ByteArray, rate: Int, floating: Boolean) {
        stop()
        stride = if (floating) 8 else 4
        require(pcm.isNotEmpty() && pcm.size % stride == 0) { "Expected complete stereo frames." }
        val channels = AudioFormat.CHANNEL_OUT_STEREO
        val encoding = if (floating) AudioFormat.ENCODING_PCM_FLOAT else AudioFormat.ENCODING_PCM_16BIT
        val minimum = AudioTrack.getMinBufferSize(rate, channels, encoding)
        check(minimum > 0) { "Stereo output is unavailable at the selected rate." }
        val format = AudioFormat.Builder().setChannelMask(channels)
            .setEncoding(encoding).setSampleRate(rate).build()
        val stream = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(format)
            .setBufferSizeInBytes(maxOf(minimum, pcm.size))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        track = stream
        check(stream.state == AudioTrack.STATE_INITIALIZED) { "Unable to open stereo output." }
        if (Build.VERSION.SDK_INT >= 31) {
            stream.setStartThresholdInFrames(minOf(stream.bufferCapacityInFrames, pcm.size / stride))
        }
        stream.play()
        write(pcm)
    }

    @Synchronized fun write(pcm: ByteArray) {
        require(pcm.size % stride == 0) { "Expected complete stereo frames." }
        val stream = checkNotNull(track) { "Audio output has stopped." }
        val floats = if (stride == 8) FloatArray(pcm.size / 4).also {
            ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(it)
        } else null
        val size = floats?.size ?: pcm.size
        var cursor = 0
        var lastProgress = SystemClock.elapsedRealtime()
        while (cursor < size) {
            val n = if (floats != null) stream.write(floats, cursor, size - cursor, AudioTrack.WRITE_NON_BLOCKING)
                else stream.write(pcm, cursor, size - cursor, AudioTrack.WRITE_NON_BLOCKING)
            check(n >= 0) { "Audio output write failed ($n)." }
            if (n == 0) {
                check(SystemClock.elapsedRealtime() - lastProgress < 2000) { "The audio route stopped accepting samples." }
                SystemClock.sleep(2)
            } else {
                cursor += n
                lastProgress = SystemClock.elapsedRealtime()
            }
        }
        accepted += pcm.size / stride
    }

    @Synchronized fun position(): Long {
        val stream = track ?: return 0
        return minOf(accepted, stream.playbackHeadPosition.toLong() and 0xffffffffL)
    }

    @Synchronized fun stop(): Long {
        val stream = track ?: return 0
        val finalFrame = position()
        track = null
        accepted = 0
        try {
            if (stream.playState == AudioTrack.PLAYSTATE_PLAYING) stream.pause()
            stream.flush()
        } finally {
            stream.release()
        }
        return finalFrame
    }
}
