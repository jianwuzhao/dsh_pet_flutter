package com.dshpet.dsh_pet_flutter

import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Android 启动壳：桌宠本体跑在 [PetOverlayService] 的悬浮窗引擎里，
/// 这里只负责授权引导（悬浮窗权限 + 通知权限）和服务的启停。
///
/// 通道协议与桌面端约定一致：overlay 引擎侧 `dsh_pet/engine#isOverlay`
/// 返回 true，本 Activity 引擎返回 false，Dart 据此决定渲染桌宠还是引导页。
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_ENGINE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isOverlay" -> result.success(false)
                    "hasOverlayPermission" -> result.success(Settings.canDrawOverlays(this))
                    "openOverlaySettings" -> {
                        // 引导用户到“显示在其他应用上层”开关页；返回结果在 onResume 后轮询。
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName"),
                            )
                        )
                        result.success(true)
                    }

                    "hasNotifications" -> {
                        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
                        result.success(manager.areNotificationsEnabled())
                    }

                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33) {
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 100)
                        }
                        result.success(true)
                    }

                    "startPet" -> {
                        startForegroundService(Intent(this, PetOverlayService::class.java))
                        // 引导页是普通全屏 Activity，留在前台会把桌面盖住、吃掉触摸；
                        // 宠物已交给悬浮窗服务，启动后立刻退回桌面。
                        moveTaskToBack(true)
                        result.success(true)
                    }

                    "stopPet" -> {
                        stopService(Intent(this, PetOverlayService::class.java))
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        const val CHANNEL_ENGINE = "dsh_pet/engine"
    }
}
