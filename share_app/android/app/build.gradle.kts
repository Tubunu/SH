plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.hengye.share.share_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.hengye.share.share_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 不加 abiFilters 时 Gradle 会把所有依赖里带的 .so 全塞进包里：用
        // `--target-platform android-arm64` 构建也会混进 armeabi-v7a / x86_64 的
        // 半套 so（v0.8 实测多出 6MB），而 32 位设备选到那套不完整的库会直接崩。
        // 这里按 Flutter 传来的 target-platform 精确裁剪；没传时保持全部 ABI。
        if ((project.findProperty("split-per-abi")?.toString() ?: "false") != "true") {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(
                    (project.findProperty("target-platform") as String?)
                        ?.split(",")
                        ?.map { it.trim() }
                        ?.filter { it.isNotEmpty() }
                        ?.map {
                            when (it) {
                                "android-arm64" -> "arm64-v8a"
                                "android-arm" -> "armeabi-v7a"
                                "android-x64" -> "x86_64"
                                "android-x86" -> "x86"
                                else -> it
                            }
                        }
                        ?: listOf("arm64-v8a", "x86_64")
                )
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
