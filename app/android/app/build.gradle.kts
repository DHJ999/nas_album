import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 发布签名（可选） ──────────────────────────────────────────────
// 存在 android/key.properties 时用正式 keystore 签 release；文件不存在则
// 退回 debug 签名 —— 也就是保持原本"直接 flutter build apk --release 就能
// 出包"的行为完全不变。key.properties 与 *.jks 都在 .gitignore 里，不入库。
//
// key.properties 内容（storeFile 路径相对于 android/app/）：
//   storeFile=../app/upload-keystore.jks
//   storePassword=...
//   keyAlias=upload
//   keyPassword=...
//
// ⚠️ 正式签名一旦用于发布就不能再更换：换了签名的 APK 无法覆盖安装旧版本。
//
// 注意：这里必须用 import 而不是 `java.util.Properties` 全限定名 ——
// Kotlin DSL 脚本里 `java` 会先解析成 Gradle 的 java 扩展，全限定名会报
// "Unresolved reference 'util'"。
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKey = keystorePropertiesFile.exists()
val keystoreProperties = Properties()
if (hasReleaseKey) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.github.dhj999.nasalbum"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.github.dhj999.nasalbum"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                // 没有 key.properties 时沿用 debug 签名（保持原行为）
                signingConfigs.getByName("debug")
            }
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
