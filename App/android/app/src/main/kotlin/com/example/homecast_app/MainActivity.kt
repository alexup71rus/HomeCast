package com.example.homecast_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.DisplayMetrics
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
	private val tag = "HomeCast"
	private val methodChannelName = "homecast/screencap"
	private val eventChannelName = "homecast/screencap_frames"
	private val audioEventChannelName = "homecast/screencap_audio"
	private val captureRequestCode = 4901

	private lateinit var projectionManager: MediaProjectionManager
	private lateinit var displayManager: DisplayManager
	private var mediaProjection: MediaProjection? = null
	private var imageReader: ImageReader? = null
	private var virtualDisplay: VirtualDisplay? = null
	private var handlerThread: HandlerThread? = null
	private var handler: Handler? = null
	private var eventSink: EventChannel.EventSink? = null
	private var audioEventSink: EventChannel.EventSink? = null
	
	// Settings
	private var targetFps: Int = 30
	private var jpegQuality: Int = 60
	private var maxVideoDim: Int = 1280
	
	// Audio
	private var audioRecord: AudioRecord? = null
	private var audioThread: Thread? = null
	@Volatile private var isAudioRunning: Boolean = false

	private var lastFrameTs: Long = 0L
	private var captureWidth: Int = 0
	private var captureHeight: Int = 0
	private var captureDensity: Int = 0
	private var frameCount: Int = 0
	private var displayListener: DisplayManager.DisplayListener? = null
	private val projectionCallback = object : MediaProjection.Callback() {
		override fun onStop() {
			Log.d(tag, "MediaProjection onStop")
			runOnUiThread {
				eventSink?.error("STOPPED", "MediaProjection stopped by system", null)
			}
			stopProjection()
		}
	}

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
		displayManager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"startCapture" -> {
						Log.d(tag, "startCapture requested")
						
						val fps = call.argument<Int>("fps")
						val quality = call.argument<Int>("quality")
						val maxDim = call.argument<Int>("width")
						
						if (fps != null) targetFps = fps
						if (quality != null) jpegQuality = quality
						if (maxDim != null) maxVideoDim = maxDim
						
						Log.d(tag, "Settings: FPS=$targetFps, Q=$jpegQuality, MaxDim=$maxVideoDim")

						if (mediaProjection != null) {
							result.success(true)
							return@setMethodCallHandler
						}
						val intent = projectionManager.createScreenCaptureIntent()
						startActivityForResult(intent, captureRequestCode)
						result.success(true)
					}
					"stopCapture" -> {
						Log.d(tag, "stopCapture requested")
						stopProjection()
						result.success(true)
					}
					else -> result.notImplemented()
				}
			}

		EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
			.setStreamHandler(object : EventChannel.StreamHandler {
				override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
					eventSink = events
				}

				override fun onCancel(arguments: Any?) {
					eventSink = null
				}
			})

		EventChannel(flutterEngine.dartExecutor.binaryMessenger, audioEventChannelName)
			.setStreamHandler(object : EventChannel.StreamHandler {
				override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
					audioEventSink = events
				}

				override fun onCancel(arguments: Any?) {
					audioEventSink = null
				}
			})
	}

	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
		super.onActivityResult(requestCode, resultCode, data)
		if (requestCode != captureRequestCode) return
		if (resultCode == Activity.RESULT_OK && data != null) {
			Log.d(tag, "MediaProjection permission granted")
			startProjection(resultCode, data)
		} else {
			Log.d(tag, "MediaProjection permission denied")
			eventSink?.endOfStream()
		}
	}

	private fun startProjection(resultCode: Int, data: Intent) {
		startForegroundCaptureService()
		Handler(Looper.getMainLooper()).postDelayed({
			if (mediaProjection == null) {
				beginProjection(resultCode, data)
			}
		}, 200)
	}

	private fun beginProjection(resultCode: Int, data: Intent) {
		if (handlerThread == null) {
			handlerThread = HandlerThread("HomeCastCapture")
			handlerThread?.start()
			handler = Handler(handlerThread!!.looper)
		}

		Log.d(tag, "Begin projection")

		mediaProjection = projectionManager.getMediaProjection(resultCode, data)
		mediaProjection?.registerCallback(projectionCallback, handler)
		
		startAudioCapture()

		val (width, height, density) = computeCaptureMetrics()
		createOrUpdateVirtualDisplay(width, height, density)
		registerDisplayListener()
	}

	private fun computeCaptureMetrics(): Triple<Int, Int, Int> {
		val metrics: DisplayMetrics = resources.displayMetrics
		var width = metrics.widthPixels
		var height = metrics.heightPixels
		val density = metrics.densityDpi
		val maxDim = maxVideoDim
		if (width > maxDim || height > maxDim) {
			val scale = maxDim.toFloat() / maxOf(width, height).toFloat()
			width = (width * scale).toInt()
			height = (height * scale).toInt()
		}
		return Triple(width, height, density)
	}

	private fun createOrUpdateVirtualDisplay(width: Int, height: Int, density: Int) {
		if (width <= 0 || height <= 0) return
		if (imageReader != null && width == captureWidth && height == captureHeight && density == captureDensity) return

		captureWidth = width
		captureHeight = height
		captureDensity = density
		frameCount = 0

		imageReader?.close()
		imageReader = null

		Log.d(tag, "Capture size: ${width}x${height} density=$density")
		imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)
		imageReader?.setOnImageAvailableListener({ reader ->
			val now = System.currentTimeMillis()
			val frameInterval = 1000 / targetFps
			if (now - lastFrameTs < frameInterval) {
				reader.acquireLatestImage()?.close()
				return@setOnImageAvailableListener
			}
			lastFrameTs = now
			val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
			try {
				val planes = image.planes
				val buffer: ByteBuffer = planes[0].buffer
				val pixelStride = planes[0].pixelStride
				val rowStride = planes[0].rowStride
				val rowPadding = rowStride - pixelStride * width

				val bitmap = Bitmap.createBitmap(
					width + rowPadding / pixelStride,
					height,
					Bitmap.Config.ARGB_8888
				)
				bitmap.copyPixelsFromBuffer(buffer)

				val cropped = Bitmap.createBitmap(bitmap, 0, 0, width, height)
				val output = ByteArrayOutputStream()
				cropped.compress(Bitmap.CompressFormat.JPEG, jpegQuality, output)
				val bytes = output.toByteArray()

				runOnUiThread {
					eventSink?.success(bytes)
				}

				frameCount++
				if (frameCount % 30 == 0) {
					Log.d(tag, "Frames sent: $frameCount")
				}
				bitmap.recycle()
				cropped.recycle()
			} catch (e: Exception) {
				Log.e(tag, "ImageReader error: ${e.message}")
			} finally {
				image.close()
			}
		}, handler)

		if (virtualDisplay == null) {
			virtualDisplay = mediaProjection?.createVirtualDisplay(
				"HomeCastCapture",
				width,
				height,
				density,
				DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR or DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC,
				imageReader?.surface,
				null,
				handler
			)
			if (virtualDisplay == null) {
				Log.e(tag, "VirtualDisplay creation failed")
			} else {
				Log.d(tag, "VirtualDisplay created")
			}
		} else {
			virtualDisplay?.setSurface(imageReader?.surface)
			virtualDisplay?.resize(width, height, density)
			Log.d(tag, "VirtualDisplay resized")
		}
	}

	private fun registerDisplayListener() {
		if (displayListener != null) return
		displayListener = object : DisplayManager.DisplayListener {
			override fun onDisplayAdded(displayId: Int) = Unit
			override fun onDisplayRemoved(displayId: Int) = Unit
			override fun onDisplayChanged(displayId: Int) {
				if (mediaProjection == null) return
				handler?.post {
					val (width, height, density) = computeCaptureMetrics()
					createOrUpdateVirtualDisplay(width, height, density)
				}
			}
		}
		displayManager.registerDisplayListener(displayListener, handler)
	}

	private fun unregisterDisplayListener() {
		val listener = displayListener ?: return
		displayManager.unregisterDisplayListener(listener)
		displayListener = null
	}

	private fun stopProjection() {
		if (mediaProjection == null && virtualDisplay == null && imageReader == null) return
		Log.d(tag, "Stop projection")
		stopAudioCapture()
		unregisterDisplayListener()
		virtualDisplay?.release()
		virtualDisplay = null
		imageReader?.close()
		imageReader = null
		captureWidth = 0
		captureHeight = 0
		mediaProjection?.unregisterCallback(projectionCallback)
		mediaProjection?.stop()
		mediaProjection = null
		stopForegroundCaptureService()
	}

	private fun startAudioCapture() {
		if (mediaProjection == null) return
		if (isAudioRunning) return
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return

		try {
			Log.d(tag, "Starting audio capture")
			val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection!!)
				.addMatchingUsage(AudioAttributes.USAGE_MEDIA)
				.addMatchingUsage(AudioAttributes.USAGE_GAME)
				.addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
				.build()

			val sampleRate = 48000
			
			val format = AudioFormat.Builder()
				.setEncoding(AudioFormat.ENCODING_PCM_16BIT)
				.setSampleRate(sampleRate)
				.setChannelMask(AudioFormat.CHANNEL_IN_MONO)
				.build()

			val minBufferSize = AudioRecord.getMinBufferSize(
				sampleRate,
				AudioFormat.CHANNEL_IN_MONO,
				AudioFormat.ENCODING_PCM_16BIT
			)
			// Use 4x min buffer for OS safety
			val bufferSize = maxOf(minBufferSize * 4, 1024 * 64)

			audioRecord = AudioRecord.Builder()
				.setAudioFormat(format)
				.setBufferSizeInBytes(bufferSize)
				.setAudioPlaybackCaptureConfig(config)
				.build()

			audioRecord?.startRecording()
			isAudioRunning = true

			audioThread = Thread {
				// Read chunks (~50ms) = 48000 * 1ch * 2bytes * 0.05s = 4800 bytes
				val frameSize = 4800 
				val pcmBuffer = ByteArray(frameSize)
				val compressedBuffer = ByteArray(frameSize / 2) // u-law is 8-bit, so 50% size
				
				android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
				
				while (isAudioRunning) {
					val read = audioRecord?.read(pcmBuffer, 0, pcmBuffer.size) ?: 0
					if (read > 0) {
						// Compress PCM16 -> uLaw8
						val sampleCount = read / 2
						for (i in 0 until sampleCount) {
							// Little Endian PCM16
							val low = pcmBuffer[i * 2].toInt() and 0xFF
							val high = pcmBuffer[i * 2 + 1].toInt()
							val sample = (high shl 8) or low
							compressedBuffer[i] = linearToULaw(sample)
						}
						
						val output = compressedBuffer.copyOf(sampleCount)
						runOnUiThread { audioEventSink?.success(output) }
					}
				}
			}
			audioThread?.start()
		} catch (e: Exception) {
			Log.e(tag, "Audio capture failed: ${e.message}")
			e.printStackTrace()
		}
	}

	private fun stopAudioCapture() {
		isAudioRunning = false
		try {
			audioThread?.join(500)
		} catch (e: Exception) {}
		audioThread = null
		
		try {
			audioRecord?.stop()
			audioRecord?.release()
		} catch (e: Exception) {}
		audioRecord = null
	}

	private fun startForegroundCaptureService() {
		val intent = Intent(this, ScreenCaptureService::class.java)
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			startForegroundService(intent)
		} else {
			startService(intent)
		}
	}

	private fun stopForegroundCaptureService() {
		stopService(Intent(this, ScreenCaptureService::class.java))
	}

	override fun onDestroy() {
		stopProjection()
		handlerThread?.quitSafely()
		handlerThread = null
		handler = null
		super.onDestroy()
	}

	// Better implementation for uLaw
	private val expLut = intArrayOf(0,0,1,1,2,2,2,2,3,3,3,3,3,3,3,3,
                                    4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,
                                    5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,
                                    5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,
                                    6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
                                    6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
                                    6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
                                    6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
                                    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
                                    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
                                    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
                                    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
                                    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
                                    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
                                    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
                                    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7)

    private fun linearToULaw(pcmValue: Int): Byte {
        var pcm = pcmValue shr 2 // Drop 2 bits (16 -> 14) 
        val sign = if (pcm < 0) 0x80 else 0
        if (pcm < 0) pcm = -pcm
        if (pcm > 32635) pcm = 32635
        pcm += 0x84
        val exponent = expLut[(pcm shr 7) and 0xFF]
        val mantissa = (pcm shr (exponent + 3)) and 0x0F
        val ulaw = (sign or (exponent shl 4) or mantissa) xor 0xFF
        return ulaw.toByte()
    }
}
