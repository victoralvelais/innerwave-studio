package studio.innerwave.innerwave_studio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.SystemClock

/** One stereo output clock for every clip. Audio focus belongs to the Dart audio session. */
internal class StereoPreview {
    private var track: AudioTrack? = null
    private var accepted = 0L

    @Synchronized fun start(pcm: ByteArray) {
        stop()
        require(pcm.isNotEmpty() && pcm.size % 4 == 0) { "Expected complete stereo frames." }
        val channels = AudioFormat.CHANNEL_OUT_STEREO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minimum = AudioTrack.getMinBufferSize(44100, channels, encoding)
        check(minimum > 0) { "44.1 kHz stereo output is unavailable." }
        val format = AudioFormat.Builder().setChannelMask(channels)
            .setEncoding(encoding).setSampleRate(44100).build()
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
            stream.setStartThresholdInFrames(minOf(stream.bufferCapacityInFrames, pcm.size / 4))
        }
        stream.play()
        write(pcm)
    }

    @Synchronized fun write(pcm: ByteArray) {
        require(pcm.size % 4 == 0) { "Expected complete stereo frames." }
        val stream = checkNotNull(track) { "Audio output has stopped." }
        var cursor = 0
        var lastProgress = SystemClock.elapsedRealtime()
        while (cursor < pcm.size) {
            val n = stream.write(pcm, cursor, pcm.size - cursor, AudioTrack.WRITE_NON_BLOCKING)
            check(n >= 0) { "Audio output write failed ($n)." }
            if (n == 0) {
                check(SystemClock.elapsedRealtime() - lastProgress < 2000) { "The audio route stopped accepting samples." }
                SystemClock.sleep(2)
            } else {
                cursor += n
                lastProgress = SystemClock.elapsedRealtime()
            }
        }
        accepted += pcm.size / 4
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
