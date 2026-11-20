package com.haishinkit.vqmetrix

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import com.haishinkit.codec.Codec
import com.haishinkit.codec.CodecOption
import com.haishinkit.codec.VideoCodec
import com.haishinkit.codec.VideoCodecProfileLevel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.File
import java.nio.ByteBuffer

data class EncodedVariant(
    val file: File,
    val bitrate: Int,
    val codec: String,
    val codecName: String,
    val hardwareAccelerated: Boolean,
    val outputPtsUs: List<Long>,
    val encodedBytes: Long,
)

class VariantEncoder(private val context: Context) {
    suspend fun encode(
        reference: File,
        captured: CapturedReference,
        target: File,
        bitrate: Int,
        format: String,
        progress: (Int) -> Unit,
    ): EncodedVariant =
        withContext(Dispatchers.IO) {
            val spec = captured.spec
            var reader: Y4mReader? = null
            val owner = VideoCodec(context)
            val muxer = MediaMuxer(target.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val completion = CompletableDeferred<Unit>()
            val outputPts = ArrayList<Long>()
            var inputIndex = 0
            var eos = false
            var track = -1
            var started = false
            var bytes = 0L
            owner.inputColorFormat = MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
            owner.width = spec.width
            owner.height = spec.height
            owner.frameRate = spec.fps
            owner.bitRate = bitrate
            owner.IFrameInterval = 2
            owner.profileLevel = if (format == "hevc") VideoCodecProfileLevel.HEVC_MAIN_4 else VideoCodecProfileLevel.H264_BASELINE_4_0
            owner.outputMimeType = owner.profileLevel.mime
            owner.options =
                buildList {
                    add(CodecOption(MediaFormat.KEY_MAX_B_FRAMES, 0))
                    if (captured.range == "limited") add(CodecOption(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED))
                    if (captured.matrix == "bt709") add(CodecOption(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709))
                    add(CodecOption(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO))
                }
            var codecName = ""
            var hardware = false
            owner.listener =
                object : Codec.Listener {
                    override fun onInputBufferAvailable(
                        mime: String,
                        codec: MediaCodec,
                        index: Int,
                    ) {
                        if (eos || completion.isCompleted) return
                        try {
                            val data = checkNotNull(reader).next()
                            owner.withCurrentCodec(codec) {
                                if (data == null) {
                                    eos = true
                                    codec.queueInputBuffer(index, 0, 0, pts(spec.frames, spec.fps), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                } else {
                                    val image = checkNotNull(codec.getInputImage(index)) { "Encoder does not support YUV input images" }
                                    YuvImages.write(image, data, spec)
                                    codec.queueInputBuffer(index, 0, data.size, pts(inputIndex, spec.fps), 0)
                                    inputIndex++
                                }
                            }
                        } catch (failure: Throwable) {
                            completion.completeExceptionally(failure)
                        }
                    }

                    override fun onFormatChanged(
                        mime: String,
                        mediaFormat: MediaFormat,
                    ) {
                        try {
                            check(!started) { "Unexpected encoder format change" }
                            track = muxer.addTrack(mediaFormat)
                            muxer.start()
                            started = true
                        } catch (failure: Throwable) {
                            completion.completeExceptionally(failure)
                        }
                    }

                    override fun onSampleOutput(
                        mime: String,
                        index: Int,
                        info: MediaCodec.BufferInfo,
                        buffer: ByteBuffer,
                    ): Boolean {
                        try {
                            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                check(started)
                                muxer.writeSampleData(track, buffer, info)
                                outputPts.add(info.presentationTimeUs)
                                bytes += info.size
                                progress(outputPts.size)
                            }
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) completion.complete(Unit)
                        } catch (failure: Throwable) {
                            completion.completeExceptionally(failure)
                        }
                        return true
                    }

                    override fun onError(
                        mime: String,
                        cause: MediaCodec.CodecException,
                    ) {
                        completion.completeExceptionally(cause)
                    }
                }
            try {
                reader = Y4mReader(reference, spec)
                val native = checkNotNull(owner.codec)
                codecName = native.name
                hardware = native.codecInfo.isHardwareAccelerated
                owner.startRunning()
                check(owner.isRunning.get()) { "Could not start $format encoder" }
                withTimeout(90_000) { completion.await() }
                owner.stopRunning()
                check(outputPts.size == spec.frames) { "Encoder produced ${outputPts.size}/${spec.frames} frames" }
                check(outputPts == (0 until spec.frames).map { pts(it, spec.fps) }) { "Encoder timestamps differ from the reference" }
                muxer.stop()
                started = false
                EncodedVariant(target, bitrate, format, codecName, hardware, outputPts.toList(), bytes)
            } finally {
                runCatching { owner.dispose() }
                reader?.close()
                try {
                    if (started) runCatching { muxer.stop() }
                } finally {
                    muxer.release()
                }
            }
        }

    companion object {
        fun pts(
            index: Int,
            fps: Int,
        ): Long = index.toLong() * 1_000_000 / fps
    }
}
