plugins {
    id("com.android.application")
}

val zon = file("../../../build.zig.zon").readText()
val versionName0 = Regex("""\.version\s*=\s*"(\d+)\.(\d+)\.(\d+)""").find(zon)
    ?: error("version not found in build.zig.zon")
val (maj, min, patch) = versionName0.destructured
val outDir = file("../../../zig-out/android")

android {
    namespace = "com.debpalash.opal"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.debpalash.opal"
        minSdk = 26
        targetSdk = 35
        versionName = "$maj.$min.$patch"
        versionCode = maj.toInt() * 10000 + min.toInt() * 100 + patch.toInt()
        ndk { abiFilters += "arm64-v8a" }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets["main"].apply {
        jniLibs.srcDir(File(outDir, "jniLibs"))
        assets.srcDir(File(outDir, "assets"))
        res.srcDir(File(outDir, "res"))
        java.srcDir((project.findProperty("sdlJavaDir") as String?) ?: File(outDir, "sdl-java").path)
    }

    val ks = System.getenv("OPAL_ANDROID_KEYSTORE")
    signingConfigs {
        if (ks != null) {
            create("release") {
                storeFile = file(ks)
                storePassword = System.getenv("OPAL_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("OPAL_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("OPAL_ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (ks != null) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs.useLegacyPackaging = true
    }
}
