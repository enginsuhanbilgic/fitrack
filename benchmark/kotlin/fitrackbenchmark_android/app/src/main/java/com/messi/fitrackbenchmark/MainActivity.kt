package com.messi.fitrackbenchmark

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.CountDownTimer
import android.os.Environment
import android.os.SystemClock
import android.util.Size
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.messi.fitrackbenchmark.engine.PoseEngine
import com.messi.fitrackbenchmark.engine.PoseEngineFactory
import com.messi.fitrackbenchmark.model.BenchmarkExporter
import com.messi.fitrackbenchmark.model.BenchmarkRecorder
import com.messi.fitrackbenchmark.model.BicepsCurlCounter
import com.messi.fitrackbenchmark.model.ModelType
import com.messi.fitrackbenchmark.ui.OverlayView
import com.messi.fitrackbenchmark.util.BitmapUtils
import com.messi.fitrackbenchmark.util.RollingFpsCounter
import java.io.File
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class MainActivity : AppCompatActivity() {

    private lateinit var cameraExecutor: ExecutorService
    private lateinit var viewFinder: PreviewView
    private lateinit var overlayView: OverlayView
    private lateinit var spinnerModel: Spinner
    private lateinit var buttonStartBenchmark: Button
    private lateinit var textModelName: TextView
    private lateinit var textLiveMetrics: TextView
    private lateinit var textSessionStatus: TextView
    private lateinit var textSavedPath: TextView

    private var currentEngine: PoseEngine? = null
    private var selectedModelType: ModelType = ModelType.ML_KIT_FAST
    private val isProcessingFrame = AtomicBoolean(false)
    private val engineEpoch = AtomicLong(0L)
    private val activeRequestToken = AtomicLong(0L)
    private val fpsCounter = RollingFpsCounter()
    private val curlCounter = BicepsCurlCounter()
    private val benchmarkRecorder = BenchmarkRecorder()
    private var benchmarkTimer: CountDownTimer? = null
    private var benchmarkRunning = false

    private val isFrontCamera = true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        viewFinder = findViewById(R.id.viewFinder)
        overlayView = findViewById(R.id.overlayView)
        spinnerModel = findViewById(R.id.spinnerModel)
        buttonStartBenchmark = findViewById(R.id.buttonStartBenchmark)
        textModelName = findViewById(R.id.textModelName)
        textLiveMetrics = findViewById(R.id.textLiveMetrics)
        textSessionStatus = findViewById(R.id.textSessionStatus)
        textSavedPath = findViewById(R.id.textSavedPath)

        viewFinder.scaleType = PreviewView.ScaleType.FIT_CENTER
        viewFinder.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        overlayView.bringToFront()
        cameraExecutor = Executors.newSingleThreadExecutor()

        setupModelSpinner()
        setupBenchmarkButton()
        switchModel(selectedModelType)

        if (allPermissionsGranted()) {
            startCamera()
        } else {
            ActivityCompat.requestPermissions(this, REQUIRED_PERMISSIONS, REQUEST_CODE_PERMISSIONS)
        }
    }

    private fun setupModelSpinner() {
        val models = ModelType.entries.toTypedArray()
        spinnerModel.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, models)
        spinnerModel.setSelection(models.indexOf(selectedModelType))
        spinnerModel.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(
                parent: AdapterView<*>?,
                view: View?,
                position: Int,
                id: Long,
            ) {
                val newModel = ModelType.entries[position]
                if (benchmarkRunning) {
                    spinnerModel.setSelection(ModelType.entries.indexOf(selectedModelType), false)
                    return
                }
                if (newModel != selectedModelType) {
                    switchModel(newModel)
                }
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
    }

    private fun setupBenchmarkButton() {
        buttonStartBenchmark.setOnClickListener {
            if (benchmarkRunning) return@setOnClickListener
            startBenchmarkSession()
        }
    }

    private fun switchModel(modelType: ModelType) {
        val oldEngine = currentEngine
        val newEpoch = engineEpoch.incrementAndGet()
        activeRequestToken.incrementAndGet()
        isProcessingFrame.set(false)
        fpsCounter.reset()
        curlCounter.reset()
        overlayView.clear()
        textLiveMetrics.text = "FPS: -- | Latency: -- | Reps: 0 | Stage: UNKNOWN"
        textSessionStatus.text = "Loading ${modelType.displayName}…"

        try {
            val newEngine = PoseEngineFactory.create(this, modelType)
            currentEngine = newEngine
            oldEngine?.close()
            selectedModelType = modelType
            textModelName.text = "Model: ${modelType.displayName}"
            textSessionStatus.text = "Ready. Face the front camera and press start."
        } catch (t: Throwable) {
            currentEngine = oldEngine
            engineEpoch.set(newEpoch - 1)
            Toast.makeText(this, "Failed to initialize ${modelType.displayName}: ${t.message}", Toast.LENGTH_LONG).show()
            textSessionStatus.text = "Failed to initialize ${modelType.displayName}."
        }
    }

    private fun startBenchmarkSession() {
        benchmarkRunning = true
        buttonStartBenchmark.isEnabled = false
        spinnerModel.isEnabled = false
        curlCounter.reset()
        fpsCounter.reset()

        val startMs = SystemClock.uptimeMillis()
        benchmarkRecorder.start(selectedModelType, startMs)
        textSessionStatus.text = "Benchmark running: 60 s remaining | Exercise: biceps curl"
        textSavedPath.text = "Recording… results will be written when the session finishes."

        benchmarkTimer?.cancel()
        benchmarkTimer = object : CountDownTimer(BENCHMARK_DURATION_MS, 1_000L) {
            override fun onTick(millisUntilFinished: Long) {
                val seconds = (millisUntilFinished + 999L) / 1000L
                textSessionStatus.text = "Benchmark running: ${seconds}s remaining | Exercise: biceps curl"
            }

            override fun onFinish() {
                finishBenchmarkSession()
            }
        }.start()
    }

    private fun finishBenchmarkSession() {
        benchmarkRunning = false
        buttonStartBenchmark.isEnabled = true
        spinnerModel.isEnabled = true

        val bundle = benchmarkRecorder.finish(SystemClock.uptimeMillis())
        val outputDir = File(getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS), "benchmarks")
        val savedFiles = BenchmarkExporter.save(bundle, outputDir)

        textSessionStatus.text = buildString {
            append("Finished | Reps: ${bundle.summary.repCount}")
            append(" | Mean latency: ${"%.1f".format(Locale.US, bundle.summary.meanLatencyMs)} ms")
            append(" | Avg FPS: ${"%.1f".format(Locale.US, bundle.summary.averageFps)}")
        }
        textSavedPath.text = "Saved JSON: ${savedFiles.summaryFile.absolutePath}\nSaved CSV: ${savedFiles.frameCsvFile.absolutePath}"
        Toast.makeText(this, "Benchmark saved.", Toast.LENGTH_LONG).show()
    }

    private fun startCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)

        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()

            val preview = Preview.Builder()
                .setTargetResolution(Size(480, 640))
                .build()
                .also { it.setSurfaceProvider(viewFinder.surfaceProvider) }

            val imageAnalyzer = ImageAnalysis.Builder()
                .setTargetResolution(Size(480, 640))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { analysis ->
                    analysis.setAnalyzer(cameraExecutor) { imageProxy ->
                        if (!isProcessingFrame.compareAndSet(false, true)) {
                            imageProxy.close()
                            return@setAnalyzer
                        }

                        val engine = currentEngine
                        if (engine == null) {
                            imageProxy.close()
                            isProcessingFrame.set(false)
                            return@setAnalyzer
                        }

                        val frameEpoch = engineEpoch.get()
                        val frameToken = activeRequestToken.incrementAndGet()

                        try {
                            val bitmap = BitmapUtils.imageProxyToUprightBitmap(imageProxy)
                            imageProxy.close()

                            val frameTimestamp = SystemClock.uptimeMillis()
                            engine.process(
                                bitmap = bitmap,
                                frameTimestampMs = frameTimestamp,
                                onResult = { result ->
                                    if (!isFrameStillCurrent(frameEpoch, frameToken)) {
                                        return@process
                                    }

                                    val rollingFps = fpsCounter.onFrameCompleted(SystemClock.uptimeMillis())
                                    val curlSnapshot = curlCounter.update(result)

                                    if (benchmarkRunning) {
                                        benchmarkRecorder.record(
                                            result = result,
                                            rollingFps = rollingFps,
                                            curlSnapshot = curlSnapshot,
                                        )
                                    }

                                    runOnUiThread {
                                        overlayView.updateResult(result, mirrorHorizontally = isFrontCamera)
                                        textLiveMetrics.text = buildString {
                                            append("FPS: ${"%.1f".format(Locale.US, rollingFps)}")
                                            append(" | Latency: ${result.latencyMs} ms")
                                            append(" | Reps: ${curlSnapshot.reps}")
                                            append(" | Stage: ${curlSnapshot.stage}")
                                            curlSnapshot.representativeAngleDeg?.let {
                                                append(" | Elbow angle: ${it.toInt()}°")
                                            }
                                        }
                                    }

                                    releaseCurrentFrame(frameEpoch, frameToken)
                                },
                                onError = { error ->
                                    if (isFrameStillCurrent(frameEpoch, frameToken)) {
                                        runOnUiThread {
                                            textSessionStatus.text = "Model error: ${error.message ?: "Unknown error"}"
                                        }
                                    }
                                    releaseCurrentFrame(frameEpoch, frameToken)
                                },
                            )
                        } catch (t: Throwable) {
                            imageProxy.close()
                            if (isFrameStillCurrent(frameEpoch, frameToken)) {
                                runOnUiThread {
                                    textSessionStatus.text = "Frame processing error: ${t.message ?: "Unknown error"}"
                                }
                            }
                            releaseCurrentFrame(frameEpoch, frameToken)
                        }
                    }
                }

            val cameraSelector = if (isFrontCamera) {
                CameraSelector.DEFAULT_FRONT_CAMERA
            } else {
                CameraSelector.DEFAULT_BACK_CAMERA
            }

            try {
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(this, cameraSelector, preview, imageAnalyzer)
            } catch (_: Exception) {
                Toast.makeText(this, "Camera failed to start.", Toast.LENGTH_SHORT).show()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun isFrameStillCurrent(frameEpoch: Long, frameToken: Long): Boolean {
        return frameEpoch == engineEpoch.get() && frameToken == activeRequestToken.get()
    }

    private fun releaseCurrentFrame(frameEpoch: Long, frameToken: Long) {
        if (isFrameStillCurrent(frameEpoch, frameToken)) {
            isProcessingFrame.set(false)
        }
    }

    private fun allPermissionsGranted(): Boolean = REQUIRED_PERMISSIONS.all {
        ContextCompat.checkSelfPermission(baseContext, it) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE_PERMISSIONS && allPermissionsGranted()) {
            startCamera()
        } else {
            Toast.makeText(this, "Camera permission is required.", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        benchmarkTimer?.cancel()
        currentEngine?.close()
        cameraExecutor.shutdown()
    }

    companion object {
        private const val REQUEST_CODE_PERMISSIONS = 42
        private const val BENCHMARK_DURATION_MS = 60_000L
        private val REQUIRED_PERMISSIONS = arrayOf(Manifest.permission.CAMERA)
    }
}
