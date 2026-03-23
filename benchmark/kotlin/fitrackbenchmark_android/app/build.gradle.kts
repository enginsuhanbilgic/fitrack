import java.net.HttpURLConnection
import java.net.URL

plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "com.messi.fitrackbenchmark"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.messi.fitrackbenchmark"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        viewBinding = false
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

val poseAssetsDir = layout.projectDirectory.dir("src/main/assets")

fun downloadWithRedirects(sourceUrl: String, destinationFile: File) {
    var currentUrl = sourceUrl
    repeat(6) {
        val connection = (URL(currentUrl).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = false
            connectTimeout = 15_000
            readTimeout = 60_000
        }

        val responseCode = connection.responseCode
        when (responseCode) {
            HttpURLConnection.HTTP_MOVED_PERM,
            HttpURLConnection.HTTP_MOVED_TEMP,
            307,
            308 -> {
                currentUrl = connection.getHeaderField("Location")
                    ?: error("Missing redirect target for $currentUrl")
                connection.disconnect()
            }
            HttpURLConnection.HTTP_OK -> {
                destinationFile.outputStream().use { output ->
                    connection.inputStream.use { input ->
                        input.copyTo(output)
                    }
                }
                connection.disconnect()
                return
            }
            else -> {
                error("Failed to download $sourceUrl. HTTP $responseCode")
            }
        }
    }
    error("Too many redirects while downloading $sourceUrl")
}

tasks.register("downloadPoseModels") {
    doLast {
        val assetsDir = poseAssetsDir.asFile
        assetsDir.mkdirs()

        val downloads = listOf(
            "movenet_singlepose_lightning_int8_4.tflite" to
                "https://tfhub.dev/google/lite-model/movenet/singlepose/lightning/tflite/int8/4?lite-format=tflite",
            "movenet_singlepose_thunder_int8_4.tflite" to
                "https://tfhub.dev/google/lite-model/movenet/singlepose/thunder/tflite/int8/4?lite-format=tflite",
            "pose_landmarker_lite.task" to
                "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/latest/pose_landmarker_lite.task",
        )

        downloads.forEach { (fileName, url) ->
            val outputFile = File(assetsDir, fileName)
            if (!outputFile.exists()) {
                println("Downloading $fileName")
                downloadWithRedirects(url, outputFile)
            } else {
                println("Skipping $fileName because it already exists.")
            }
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn("downloadPoseModels")
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.material)
    implementation(libs.androidx.activity)
    implementation(libs.androidx.constraintlayout)

    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)

    implementation(libs.mlkit.pose.detection)
    implementation(libs.mlkit.pose.accurate)

    implementation(libs.mediapipe.tasks.vision)
    implementation(libs.tensorflow.lite)

    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}
