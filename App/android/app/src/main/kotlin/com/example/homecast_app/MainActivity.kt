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
	private val captureRequestCode = 4901

	private lateinit var projectionManager: MediaProjectionManager
	private lateinit var displayManager: DisplayManager
	private var mediaProjection: MediaProjection? = null
	private var imageReader: ImageReader? = null
	private var virtualDisplay: VirtualDisplay? = null
	private var handlerThread: HandlerThread? = null
	private var handler: Handler? = null
	private var eventSink: EventChannel.EventSink? = null
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

		val (width, height, density) = computeCaptureMetrics()
		createOrUpdateVirtualDisplay(width, height, density)
		registerDisplayListener()
	}

	private fun computeCaptureMetrics(): Triple<Int, Int, Int> {
		val metrics: DisplayMetrics = resources.displayMetrics
		var width = metrics.widthPixels
		var height = metrics.heightPixels
		val density = metrics.densityDpi
		val maxDim = 1280
		if (width > maxDim || height > maxDim) {
			val scale = maxDim.toFloat() / maxOf(width, height).toFloat()
			width = (width * scale).toInt()
			height = (height * scale).toInt()
		}
		return Triple(width, height, density)
	}

	private fun createOrUpdateVirtualDisplay(width: Int, height: Int, density: Int) {
		if (width <= 0 || height <= 0) return
		if (width == captureWidth && height == captureHeight && density == captureDensity) return

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
			if (now - lastFrameTs < 66) {
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
				cropped.compress(Bitmap.CompressFormat.JPEG, 60, output)
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
		unregisterDisplayListener()
		virtualDisplay?.release()
		virtualDisplay = null
		imageReader?.close()
		imageReader = null
		mediaProjection?.unregisterCallback(projectionCallback)
		mediaProjection?.stop()
		mediaProjection = null
		stopForegroundCaptureService()
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
}
