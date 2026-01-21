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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import androidx.activity.result.contract.ActivityResultContracts
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
	private val methodChannelName = "homecast/screencap"
	private val eventChannelName = "homecast/screencap_frames"

	private lateinit var projectionManager: MediaProjectionManager
	private var mediaProjection: MediaProjection? = null
	private var imageReader: ImageReader? = null
	private var virtualDisplay: VirtualDisplay? = null
	private var handlerThread: HandlerThread? = null
	private var handler: Handler? = null
	private var eventSink: EventChannel.EventSink? = null
	private var lastFrameTs: Long = 0L

	private val captureLauncher = registerForActivityResult(
		ActivityResultContracts.StartActivityForResult()
	) { result ->
		if (result.resultCode == Activity.RESULT_OK && result.data != null) {
			startProjection(result.resultCode, result.data!!)
		} else {
			eventSink?.endOfStream()
		}
	}

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"startCapture" -> {
						if (mediaProjection != null) {
							result.success(true)
							return@setMethodCallHandler
						}
						val intent = projectionManager.createScreenCaptureIntent()
						captureLauncher.launch(intent)
						result.success(true)
					}
					"stopCapture" -> {
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

	private fun startProjection(resultCode: Int, data: Intent) {
		mediaProjection = projectionManager.getMediaProjection(resultCode, data)

		if (handlerThread == null) {
			handlerThread = HandlerThread("HomeCastCapture")
			handlerThread?.start()
			handler = Handler(handlerThread!!.looper)
		}

		val metrics: DisplayMetrics = resources.displayMetrics
		val width = metrics.widthPixels
		val height = metrics.heightPixels
		val density = metrics.densityDpi

		imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
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
				eventSink?.success(bytes)
				bitmap.recycle()
				cropped.recycle()
			} catch (_: Exception) {
				// ignore
			} finally {
				image.close()
			}
		}, handler)

		virtualDisplay = mediaProjection?.createVirtualDisplay(
			"HomeCastCapture",
			width,
			height,
			density,
			DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
			imageReader?.surface,
			null,
			handler
		)

		startForegroundCaptureService()
	}

	private fun stopProjection() {
		virtualDisplay?.release()
		virtualDisplay = null
		imageReader?.close()
		imageReader = null
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
