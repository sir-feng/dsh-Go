package io.github.ccch1mneyyy.dsh_app.pet

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.github.ccch1mneyyy.dsh_app.shortcuts.ScreenshotFiles
import java.io.File
import java.io.FilterOutputStream
import java.io.IOException
import java.io.OutputStream
import java.lang.reflect.Method
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * User-initiated, unmarked capture. Nothing is uploaded or written to shared storage here.
 *
 * Uses MediaProjection via reflection: AGP 9.1.0 + Kotlin 2.4.0 does not expose
 * `android.media.projection.*` to the Kotlin compiler at compileSdk 35 or 36, so the symbols
 * cannot be referenced directly. All MediaProjection / ImageReader / VirtualDisplay access goes
 * through reflection; Display.getMetrics is reflected too.
 */
internal object PetScreenshot {
    enum class Error { UNSUPPORTED, CAPTURE_REQUIRED, SECURE, BUSY, FAILED, TIMEOUT }
    data class Result(val path: String? = null, val error: Error? = null)

    private const val TIMEOUT_MS = 8_000L
    private const val SETTLE_MS = 120L
    /** One frame is enough; the screen is static while the pet is hidden. */
    private const val FRAME_WAIT_MS = 500L
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private val worker by lazy {
        Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-pet-shot").apply { isDaemon = true } }
    }
    private var active: Capture? = null // main thread only

    // Reflection handles (lazily resolved; null when the class is absent on the running API).
    private val mgrServiceCls by lazy { Class.forName("android.media.projection.MediaProjectionManager") }
    private val projectionCls by lazy { Class.forName("android.media.projection.MediaProjection") }
    private val readerCls by lazy { Class.forName("android.media.ImageReader") }
    private val virtualCls by lazy { Class.forName("android.hardware.display.VirtualDisplay") }

    private val mgrCreateIntent: Method by lazy { mgrServiceCls.getMethod("createScreenCaptureIntent") }
    private val mgrGetProjection: Method by lazy { mgrServiceCls.getMethod("getMediaProjection", Int::class.javaPrimitiveType, Intent::class.java) }
    private val projectionCreateVirtual: Method by lazy {
        projectionCls.getMethod(
            "createVirtualDisplay", String::class.java, Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType, android.view.Surface::class.java, Handler::class.java,
        )
    }
    private val projectionStop: Method by lazy { projectionCls.getMethod("stop") }
    private val readerNewInstance: Method by lazy {
        // ImageReader.newInstance(width, height, ImageFormat.RGBA_8888, maxImages)
        readerCls.getMethod("newInstance", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
    }
    private val readerAcquire: Method by lazy { readerCls.getMethod("acquireLatestImage") }
    private val readerClose: Method by lazy { readerCls.getMethod("close") }
    private val readerSurface: Method by lazy { readerCls.getMethod("getSurface") }
    private val virtualRelease: Method by lazy { virtualCls.getMethod("release") }

    private val imageCls by lazy { Class.forName("android.media.Image") }
    private val imageWidth: Method by lazy { imageCls.getMethod("getWidth") }
    private val imageHeight: Method by lazy { imageCls.getMethod("getHeight") }
    private val imagePlanes: Method by lazy { imageCls.getMethod("getPlanes") }
    private val imageClose: Method by lazy { imageCls.getMethod("close") }
    private val planeCls by lazy { Class.forName("android.media.ImagePlane") }
    private val planeBuffer: Method by lazy { planeCls.getMethod("getBuffer") }
    private val planeRowStride: Method by lazy { planeCls.getMethod("getRowStride") }
    private val planePixelStride: Method by lazy { planeCls.getMethod("getPixelStride") }

    private val displayGetMetrics: Method by lazy {
        Class.forName("android.view.Display").getMethod("getMetrics", android.util.DisplayMetrics::class.java)
    }

    private class Capture(
        val context: Context,
        val activity: Activity,
        val callback: (Result) -> Unit,
        var projection: Any? = null,
        var reader: Any? = null,
        var virtual: Any? = null,
    ) {
        val completion = PetScreenshotCompletion()
        lateinit var timeout: Runnable
    }

    /**
     * Captures the default display via MediaProjection. [activity] is required to request the
     * screen-record permission; when it is null or the SDK is below 30 the call fails fast. The
     * caller hides its pet windows first. Results are delivered once, on the main thread.
     */
    fun capture(context: Context, activity: Activity?, callback: (Result) -> Unit) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { capture(context.applicationContext, activity, callback) }
            return
        }
        if (Build.VERSION.SDK_INT < 30) { callback(Result(error = Error.UNSUPPORTED)); return }
        if (active != null) { callback(Result(error = Error.BUSY)); return }
        val app = context.applicationContext
        if (activity == null) { callback(Result(error = Error.CAPTURE_REQUIRED)); return }
        val manager = app.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
        if (manager == null || !mgrServiceCls.isInstance(manager)) { callback(Result(error = Error.UNSUPPORTED)); return }
        val capture = Capture(app, activity, callback)
        active = capture
        capture.timeout = Runnable { finish(capture, Result(error = Error.TIMEOUT)) }
        main.postDelayed(capture.timeout, TIMEOUT_MS)
        try {
            // The permission dialog is a new task on top; the pet windows stay hidden behind it.
            val intent = mgrCreateIntent.invoke(manager) as Intent
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (_: Exception) { finish(capture, Result(error = Error.FAILED)) }
    }

    const val REQUEST_CODE = 0x5C31

    /** Delivered from the activity's onActivityResult; the result code is the permission answer. */
    fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CODE) return
        val capture = active ?: return
        if (resultCode != Activity.RESULT_OK || data == null) {
            finish(capture, Result(error = Error.CAPTURE_REQUIRED))
            return
        }
        try {
            val manager = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
            if (manager == null || !mgrServiceCls.isInstance(manager)) {
                finish(capture, Result(error = Error.UNSUPPORTED)); return
            }
            val projection = mgrGetProjection.invoke(manager, resultCode, data)
            if (projection == null) { finish(capture, Result(error = Error.CAPTURE_REQUIRED)); return }
            val (w, h, dpi) = displayMetrics(activity)
            val reader = readerNewInstance.invoke(null, w, h, 1 /* RGBA_8888 */, 2)
            val surface = readerSurface.invoke(reader) as android.view.Surface
            val virtual = projectionCreateVirtual.invoke(
                projection, "dsh-pet-shot", w, h,
                dpi, 1 /* VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR */, surface, null,
            ) ?: run {
                projectionStop.invoke(projection)
                finish(capture, Result(error = Error.FAILED))
                return
            }
            capture.projection = projection
            capture.reader = reader
            capture.virtual = virtual
            // Also lets WindowManager commit removal of the pet/wheel windows before capture.
            main.postDelayed({ start(capture) }, SETTLE_MS)
        } catch (_: SecurityException) { finish(capture, Result(error = Error.CAPTURE_REQUIRED)) }
        catch (_: Exception) { finish(capture, Result(error = Error.FAILED)) }
    }

    /** Drop a completed frame when its pet generation/gesture is no longer current. */
    fun discard(context: Context, path: String) {
        val cache = context.applicationContext.cacheDir
        worker.execute {
            runCatching { ScreenshotFiles.validate(cache, path)?.parentFile?.let(ScreenshotFiles::deleteSlot) }
        }
    }

    private fun start(capture: Capture) {
        if (capture.completion.finished) return
        try {
            val deadline = System.currentTimeMillis() + FRAME_WAIT_MS
            while (System.currentTimeMillis() < deadline) {
                val image = try { readerAcquire.invoke(capture.reader) } catch (_: Exception) { null }
                if (image != null) {
                    var bitmap: Bitmap? = null
                    try {
                        bitmap = imageToBitmap(image)
                        if (!capture.completion.finished) {
                            main.post {
                                val b = bitmap ?: return@post
                                val result = save(capture, b)
                                b.recycle()
                                finish(capture, result)
                            }
                        }
                    } finally { imageClose.invoke(image) }
                    return
                }
                Thread.sleep(20)
            }
            main.post { finish(capture, Result(error = Error.TIMEOUT)) }
        } catch (_: Exception) { main.post { finish(capture, Result(error = Error.FAILED)) } }
    }

    private fun imageToBitmap(image: Any): Bitmap {
        val width = imageWidth.invoke(image) as Int
        val height = imageHeight.invoke(image) as Int
        val planes = imagePlanes.invoke(image) as Array<*>
        val plane = planes[0]
        val buffer = planeBuffer.invoke(plane) as java.nio.ByteBuffer
        val rowStride = planeRowStride.invoke(plane) as Int
        val pixelStride = planePixelStride.invoke(plane) as Int
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(width * height)
        for (y in 0 until height) {
            var rowOffset = y * rowStride
            for (x in 0 until width) {
                val r = buffer.get(rowOffset).toInt() and 0xff
                val g = buffer.get(rowOffset + 1).toInt() and 0xff
                val b = buffer.get(rowOffset + 2).toInt() and 0xff
                val a = buffer.get(rowOffset + 3).toInt() and 0xff
                pixels[y * width + x] = (a shl 24) or (r shl 16) or (g shl 8) or b
                rowOffset += pixelStride
            }
        }
        bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
        return bitmap
    }

    private fun displayMetrics(activity: Activity): Triple<Int, Int, Int> {
        val display = activity.windowManager.defaultDisplay
        val metrics = android.util.DisplayMetrics()
        runCatching { displayGetMetrics.invoke(display, metrics) }
        return Triple(metrics.widthPixels, metrics.heightPixels, metrics.densityDpi)
    }

    private fun release(capture: Capture) {
        runCatching { capture.virtual?.let(virtualRelease::invoke) }
        runCatching { capture.reader?.let(readerClose::invoke) }
        runCatching { capture.projection?.let(projectionStop::invoke) }
    }

    private fun finish(capture: Capture, result: Result): Boolean {
        if (!capture.completion.tryFinish()) return false
        main.removeCallbacks(capture.timeout)
        if (active === capture) active = null
        release(capture)
        capture.callback(result)
        return true
    }

    private fun save(capture: Capture, bitmap: Bitmap): Result {
        // Older Android versions may blank FLAG_SECURE instead of returning the secure error.
        if (looksProtected(bitmap)) return Result(error = Error.SECURE)
        if (capture.completion.finished) return Result(error = Error.TIMEOUT)
        val slot = ScreenshotFiles.createSlot(capture.context.cacheDir)
        var keep = false
        try {
            val (width, height) = PetScreenshotPolicy.size(bitmap.width, bitmap.height)
            val scaled = if (width != bitmap.width || height != bitmap.height)
                Bitmap.createScaledBitmap(bitmap, width, height, true) else bitmap
            try {
                var file = File(slot, "screenshot.png")
                try { compress(scaled, Bitmap.CompressFormat.PNG, 100, file) }
                catch (_: SizeLimitExceeded) {
                    file.delete()
                    file = File(slot, "screenshot.jpg")
                    compress(scaled, Bitmap.CompressFormat.JPEG, 92, file)
                }
                if (capture.completion.finished) return Result(error = Error.TIMEOUT)
                val path = ScreenshotFiles.validate(capture.context.cacheDir, file.canonicalPath)?.path
                    ?: return Result(error = Error.FAILED)
                keep = true
                return Result(path = path)
            } finally { if (scaled !== bitmap) scaled.recycle() }
        } finally { if (!keep) ScreenshotFiles.deleteSlot(slot) }
    }

    private fun compress(bitmap: Bitmap, format: Bitmap.CompressFormat, quality: Int, file: File) {
        file.outputStream().buffered().use { out ->
            val limited = LimitedOutput(out)
            val encoded = bitmap.compress(format, quality, limited)
            // Some Android encoders return false instead of propagating a stream exception.
            if (limited.exceeded) throw SizeLimitExceeded()
            if (!encoded) throw IOException("Cannot encode screenshot")
        }
    }

    private class SizeLimitExceeded : IOException()
    private class LimitedOutput(out: OutputStream) : FilterOutputStream(out) {
        private var written = 0L
        var exceeded = false
            private set
        override fun write(value: Int) { reserve(1); out.write(value) }
        override fun write(bytes: ByteArray, offset: Int, length: Int) { reserve(length); out.write(bytes, offset, length) }
        private fun reserve(count: Int) {
            if (written + count > ScreenshotFiles.MAX_BYTES) { exceeded = true; throw SizeLimitExceeded() }
            written += count
        }
    }

    private fun looksProtected(bitmap: Bitmap): Boolean {
        var dark = 0
        val count = 32
        for (x in 0 until count) for (y in 0 until count) {
            val pixel = bitmap.getPixel((bitmap.width - 1) * x / (count - 1), (bitmap.height - 1) * y / (count - 1))
            if (max(Color.red(pixel), max(Color.green(pixel), Color.blue(pixel))) < 12) dark++
        }
        return dark >= count * count * 97 / 100
    }
}

/** Kept independent of Android callbacks so timeout/late completion races can be unit-tested. */
internal class PetScreenshotCompletion {
    private val done = AtomicBoolean(false)
    val finished: Boolean get() = done.get()
    fun tryFinish(): Boolean = done.compareAndSet(false, true)
}

internal object PetScreenshotPolicy {
    fun size(width: Int, height: Int): Pair<Int, Int> {
        require(width > 0 && height > 0)
        val scale = minOf(1.0, 2048.0 / max(width, height))
        return (width * scale).roundToInt().coerceAtLeast(1) to (height * scale).roundToInt().coerceAtLeast(1)
    }
}
