package com.hengye.share.share_app

import android.content.ComponentName
import android.content.pm.PackageManager
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.hengye.share/cookies",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCookies" -> {
                    val url = call.argument<String>("url")
                    val allDomains = call.argument<Boolean>("allDomains") ?: true
                    val cm = CookieManager.getInstance()
                    cm.flush()
                    val merged = linkedMapOf<String, String>()
                    val targets = buildList {
                        if (!url.isNullOrBlank()) add(url)
                        if (allDomains) {
                            addAll(
                                listOf(
                                    "https://weibo.com",
                                    "https://m.weibo.cn",
                                    "https://api.weibo.cn",
                                    "https://passport.weibo.cn",
                                    "https://login.sina.com.cn",
                                ),
                            )
                        }
                    }
                    for (target in targets) {
                        val raw = cm.getCookie(target) ?: continue
                        for (part in raw.split(";")) {
                            val trimmed = part.trim()
                            val eq = trimmed.indexOf('=')
                            if (eq > 0) {
                                val k = trimmed.substring(0, eq).trim()
                                val v = trimmed.substring(eq + 1).trim()
                                if (k.isNotEmpty() && v.isNotEmpty()) {
                                    merged[k] = v
                                }
                            }
                        }
                    }
                    result.success(merged.entries.joinToString("; ") { "${it.key}=${it.value}" })
                }

                "clearCookies" -> {
                    val cm = CookieManager.getInstance()
                    cm.removeAllCookies { cleared ->
                        cm.flush()
                        result.success(cleared)
                    }
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.hengye.share/platform",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setLauncherIcon" -> {
                    val targetAlias = call.argument<String>("alias") ?: "Launcher"
                    val aliases = listOf("Launcher", "Launcher2", "Launcher3", "Launcher4", "Launcher5")
                    try {
                        var switchedAny = false
                        val pm = packageManager
                        for (alias in aliases) {
                            val cn = ComponentName(packageName, "$packageName.$alias")
                            val info = runCatching {
                                pm.getActivityInfo(cn, PackageManager.MATCH_DISABLED_COMPONENTS)
                            }.getOrNull()
                            if (info != null) {
                                switchedAny = true
                                val state = if (alias == targetAlias) {
                                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                                } else {
                                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                                }
                                pm.setComponentEnabledSetting(cn, state, PackageManager.DONT_KILL_APP)
                            }
                        }
                        result.success(switchedAny)
                    } catch (_: Throwable) {
                        result.success(false)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
