package com.dshpet.dsh_pet_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Point
import android.graphics.PixelFormat
import android.net.Uri
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/// 桌宠本体：前台服务 + 全屏透明悬浮窗。
///
/// 窗口形态对齐桌面端（无边框透明置顶 + 点击穿透）：
/// - 渲染层：全屏 FlutterView，默认 `FLAG_NOT_TOUCHABLE`（穿透），
///   `setInteractive(true)` 时整窗可交互（菜单、拖拽、面板），与 macOS
///   `ignoresMouseEvents` / Windows `WS_EX_TRANSPARENT` 的语义一致。
/// - 哨兵层：宠物大小的透明 View 跟随宠物位置。触摸平台没有 hover 光标，
///   手指按下前无法预开交互，默认穿透状态下靠哨兵接收第一下触摸，
///   再转成 `dsh_pet/cursor` 事件流驱动 Dart 侧的拖拽/点击手势。
/// - 前台通知即“托盘”：对话 / 设置 / 隐藏 / 退出。
class PetOverlayService : Service() {

    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var sentinel: View? = null
    private lateinit var windowManager: WindowManager

    private var cursorSink: EventChannel.EventSink? = null
    private var appSink: EventChannel.EventSink? = null
    private var visible = true
    private var overlayVisible = false

    // 哨兵跟随的宠物命中区（逻辑像素），换算成物理像素挪 View。
    private var hitLeft = 0f
    private var hitTop = 0f
    private var hitWidth = 0f
    private var hitHeight = 0f

    private val density: Float
        get() = resources.displayMetrics.density

    // ---------------------------------------------------------------------------
    // 生命周期
    // ---------------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        AccessibilityHub.subscribe(::onAppEvent)
        installEngine()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        when (intent?.action) {
            ACTION_CHAT -> invokeTrayAction("chat")
            ACTION_SETTINGS -> invokeTrayAction("settings")
            ACTION_QUIT -> quit()
            ACTION_TOGGLE -> setPetVisible(!visible)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        AccessibilityHub.unsubscribe(::onAppEvent)
        removeOverlay()
        engine?.apply {
            destroy()
        }
        engine = null
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 旋转 / 折叠 / 分屏改变了可用区域：像桌面端 WM_DISPLAYCHANGE 一样推送重铺。
        applyOverlayFrame()
        pushScreensChanged()
    }

    // ---------------------------------------------------------------------------
    // 引擎与悬浮窗
    // ---------------------------------------------------------------------------

    private fun installEngine() {
        val engine = FlutterEngine(this)
        this.engine = engine

        installChannels(engine)

        // overlay entrypoint 直接渲染桌宠（PetApp），不走引导页 main()。
        val appBundle = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        engine.dartExecutor.executeDartEntrypoint(
            io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint(appBundle, "overlay")
        )
        engine.lifecycleChannel.appIsResumed()

        // texture 渲染 + setOpaque(false)：桌宠悬浮窗只能走 TextureView。
        // 默认的 SurfaceView 会另开一个全屏独立子表面窗口：
        // 1) 宿主应用退后台时该子表面被系统剔除不合成，宠物直接消失；
        // 2) 它与悬浮窗叠加的遮蔽度达 0.96，触发 Android 12+ “不可信触摸”
        //    保护，把下方应用的所有触摸事件丢弃（表现为“挡住点不了”）。
        // TextureView 直接画进悬浮窗自己的表面，两个问题都不存在。
        val textureView = FlutterTextureView(this).apply { setOpaque(false) }
        val view = FlutterView(this, textureView)
        view.attachToFlutterEngine(engine)
        flutterView = view
        windowManager.addView(view, buildRenderParams())

        val sentinel = SentinelView(this)
        this.sentinel = sentinel
        windowManager.addView(sentinel, buildSentinelParams())

        overlayVisible = true
        applyOverlayFrame()
    }

    private fun removeOverlay() {
        sentinel?.let { windowManager.removeView(it) }
        flutterView?.let { view ->
            view.detachFromFlutterEngine()
            windowManager.removeView(view)
        }
        sentinel = null
        flutterView = null
        overlayVisible = false
    }

    /// 全屏渲染层：透明、置顶、默认穿透、不抢焦点。
    private fun buildRenderParams(): WindowManager.LayoutParams =
        WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }

    /// 哨兵层：初始 1x1 藏在角落，等 Dart 推来真实命中区再展开。
    private fun buildSentinelParams(): WindowManager.LayoutParams =
        WindowManager.LayoutParams(
            1,
            1,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }

    /// 把悬浮窗铺满当前可用屏幕（物理像素；状态栏/导航栏区域也允许绘制）。
    private fun applyOverlayFrame() {
        val view = flutterView ?: return
        val size = screenPhysicalSize()
        windowManager.updateViewLayout(
            view,
            buildRenderParams().apply {
                width = size.x
                height = size.y
            }
        )
    }

    /// 全屏物理尺寸：maximumWindowMetrics 是 API 30+，旧设备退回 realSize。
    private fun screenPhysicalSize(): Point =
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            windowManager.maximumWindowMetrics.bounds.let { Point(it.width(), it.height()) }
        } else {
            Point().also { @Suppress("DEPRECATION") windowManager.defaultDisplay.getRealSize(it) }
        }

    /// 屏幕逻辑尺寸：Dart 把它当作窗口本地坐标系的可用域。
    private fun screenLogicalSize(): Pair<Int, Int> {
        val size = screenPhysicalSize()
        val density = density
        return Pair(
            (size.x / density).toInt().coerceAtLeast(1),
            (size.y / density).toInt().coerceAtLeast(1),
        )
    }

    private fun lastPointerLogical(): Map<String, Any> {
        val size = screenPhysicalSize()
        val density = density
        return mapOf(
            "x" to (size.x / 2 / density).toDouble(),
            "y" to (size.y / 2 / density).toDouble(),
        )
    }

    // ---------------------------------------------------------------------------
    // 通道：协议与 macOS / Windows 完全一致
    // ---------------------------------------------------------------------------

    private fun installChannels(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger

        MethodChannel(messenger, CHANNEL_ENGINE).setMethodCallHandler { call, result ->
            when (call.method) {
                "isOverlay" -> result.success(true)
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, CHANNEL_WINDOW).setMethodCallHandler { call, result ->
            handleWindowCall(call.method, call.arguments, result)
        }

        MethodChannel(messenger, CHANNEL_CONTENT).setMethodCallHandler { call, result ->
            when (call.method) {
                "isTrusted" -> result.success(PetAccessibilityService.isConnected())
                "requestTrust" -> {
                    // 无障碍开关没有深链定值页，只能送到服务列表让用户自己开。
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(true)
                }

                "readFocusedText" -> {
                    val content = PetAccessibilityService.readFocusedContent()
                    if (content == null) {
                        result.error("read.denied", "无障碍服务未开启或读不到焦点元素", null)
                    } else {
                        result.success(content)
                    }
                }

                "notify" -> {
                    val arguments = call.arguments as? Map<*, *> ?: mapOf<String, Any>()
                    showBubbleNotification(
                        title = arguments["title"] as? String ?: "桌宠",
                        body = arguments["body"] as? String ?: "",
                    )
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, CHANNEL_INPUT).setMethodCallHandler { call, result ->
            when (call.method) {
                "activateApp" -> {
                    // Android 侧 bundleId 约定 = 应用包名（如 com.trae.cn）。
                    val packageName = call.arguments as? String ?: ""
                    val intent = packageManager.getLaunchIntentForPackage(packageName)
                    if (intent == null) {
                        result.success(false)
                    } else {
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    }
                }

                "openUrl" -> {
                    val url = (call.arguments as? Map<*, *>)?.get("url") as? String ?: ""
                    try {
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }

                // Android 不允许应用间注入粘贴+回车；联动走 Trae 扩展桥或深链。
                "pasteAndSubmit" -> result.success(false)
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, CHANNEL_CURSOR).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                cursorSink = events
            }

            override fun onCancel(arguments: Any?) {
                cursorSink = null
            }
        })

        EventChannel(messenger, CHANNEL_APP).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                appSink = events
                // 订阅即推当前前台应用，Dart 启动时就能拿到一次快照。
                AccessibilityHub.latest()?.let(::pushAppEvent)
            }

            override fun onCancel(arguments: Any?) {
                appSink = null
            }
        })
    }

    private fun handleWindowCall(method: String, rawArguments: Any?, result: MethodChannel.Result) {
        when (method) {
            "setInteractive" -> {
                val interactive = rawArguments as? Boolean ?: false
                setRenderInteractive(interactive)
                result.success(true)
            }

            "setFocusable" -> {
                val focusable = rawArguments as? Boolean ?: false
                setRenderFocusable(focusable)
                result.success(true)
            }

            // 悬浮窗天然置顶，语义上恒成功。
            "setAlwaysOnTop" -> result.success(true)

            "isVisible" -> result.success(visible)

            "showWindow" -> {
                setPetVisible(true)
                result.success(true)
            }

            "hideWindow" -> {
                setPetVisible(false)
                result.success(true)
            }

            "getScreens" -> {
                val (width, height) = screenLogicalSize()
                result.success(listOf(mapOf("x" to 0.0, "y" to 0.0, "width" to width.toDouble(), "height" to height.toDouble())))
            }

            // 单屏设备没有“搬去另一块屏”：把当前屏当作目标屏原样返回。
            "moveToScreen" -> {
                val (width, height) = screenLogicalSize()
                result.success(
                    mapOf(
                        "index" to 0,
                        "width" to width.toDouble(),
                        "height" to height.toDouble(),
                        "pointer" to lastPointerLogical(),
                    )
                )
            }

            "updateHitRect" -> {
                val arguments = rawArguments as? Map<*, *> ?: mapOf<String, Any>()
                hitLeft = (arguments["x"] as? Number ?: 0).toFloat()
                hitTop = (arguments["y"] as? Number ?: 0).toFloat()
                hitWidth = (arguments["width"] as? Number ?: 0).toFloat()
                hitHeight = (arguments["height"] as? Number ?: 0).toFloat()
                applySentinelFrame()
                result.success(true)
            }

            "windowState" -> {
                val (width, height) = screenLogicalSize()
                result.success(
                    mapOf(
                        "visible" to visible,
                        "frame" to mapOf("x" to 0.0, "y" to 0.0, "width" to width.toDouble(), "height" to height.toDouble()),
                        "activeScreenIndex" to 0,
                        "activeScreen" to mapOf("x" to 0.0, "y" to 0.0, "width" to width.toDouble(), "height" to height.toDouble()),
                        "screens" to listOf(
                            mapOf("x" to 0.0, "y" to 0.0, "width" to width.toDouble(), "height" to height.toDouble())
                        ),
                    )
                )
            }

            "quit" -> {
                quit()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------------
    // 窗口形态切换
    // ---------------------------------------------------------------------------

    private fun setRenderInteractive(interactive: Boolean) {
        val view = flutterView ?: return
        if (!overlayVisible) return
        val size = screenPhysicalSize()
        val params = buildRenderParams().apply {
            width = size.x
            height = size.y
        }
        if (interactive) {
            params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        }
        windowManager.updateViewLayout(view, params)
        applySentinelFrame()
    }

    private fun setRenderFocusable(focusable: Boolean) {
        val view = flutterView ?: return
        if (!overlayVisible) return
        val size = screenPhysicalSize()
        val params = buildRenderParams().apply {
            width = size.x
            height = size.y
        }
        if (focusable) {
            // 面板要软键盘：去掉 NOT_FOCUSABLE（会临时抢全局输入焦点，与桌面端同语义）。
            params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
        }
        windowManager.updateViewLayout(view, params)
        applySentinelFrame()
    }

    private fun setPetVisible(next: Boolean) {
        visible = next
        val view = flutterView
        if (view != null && overlayVisible) {
            view.visibility = if (next) View.VISIBLE else View.GONE
        }
        sentinel?.visibility = if (next) View.VISIBLE else View.GONE
        refreshTrayNotification()
    }

    /// 哨兵只覆盖宠物命中区（逻辑 px -> 物理 px）；交互窗接管期间藏起避免双层接触摸。
    private fun applySentinelFrame() {
        val sentinel = sentinel ?: return
        val density = density
        val params = buildSentinelParams().apply {
            x = (hitLeft * density).toInt()
            y = (hitTop * density).toInt()
            width = (hitWidth * density).toInt().coerceAtLeast(1)
            height = (hitHeight * density).toInt().coerceAtLeast(1)
        }
        // 渲染层整窗可交互（菜单/面板/拖拽）时 Flutter 手势自己接管，哨兵退场。
        val renderTakesInput = flutterView?.let { view ->
            (view.layoutParams as? WindowManager.LayoutParams)
                ?.flags?.and(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE) == 0
        } == true
        sentinel.visibility = if (visible && !renderTakesInput) View.VISIBLE else View.GONE
        if (overlayVisible) windowManager.updateViewLayout(sentinel, params)
    }

    // ---------------------------------------------------------------------------
    // 哨兵 -> 光标事件流
    // ---------------------------------------------------------------------------

    private fun pushPointer(x: Float, y: Float, down: Boolean) {
        val sink = cursorSink ?: return
        val density = density
        sink.success(
            mapOf(
                "x" to (x / density).toDouble(),
                "y" to (y / density).toDouble(),
                "down" to down,
            )
        )
    }

    /// 触摸平台没有“光标离开”事件：抬手后补一发屏外坐标，
    /// 让 Dart 侧 hitTest 判否、把窗口翻回穿透。
    private fun pushPointerGone() {
        cursorSink?.success(mapOf("x" to -9999.0, "y" to -9999.0, "down" to false))
    }

    private inner class SentinelView(context: Context) : View(context) {
        override fun onTouchEvent(event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> pushPointer(event.rawX, event.rawY, true)
                MotionEvent.ACTION_MOVE -> pushPointer(event.rawX, event.rawY, true)
                MotionEvent.ACTION_UP -> {
                    pushPointer(event.rawX, event.rawY, false)
                    pushPointerGone()
                }

                MotionEvent.ACTION_CANCEL -> {
                    pushPointer(event.rawX, event.rawY, false)
                    pushPointerGone()
                }
            }
            return true
        }
    }

    // ---------------------------------------------------------------------------
    // 前台通知（托盘）
    // ---------------------------------------------------------------------------

    private fun startAsForeground() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_TRAY, getString(R.string.tray_channel_name), NotificationManager.IMPORTANCE_LOW)
        )
        startForeground(TRAY_NOTIFICATION_ID, buildTrayNotification())
    }

    private fun trayAction(action: String): PendingIntent =
        PendingIntent.getService(
            this,
            action.hashCode(),
            Intent(this, PetOverlayService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun buildTrayNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_TRAY)
            .setSmallIcon(R.drawable.ic_stat_pet)
            .setContentTitle(getString(R.string.tray_title))
            .setContentText(getString(R.string.tray_text))
            .setContentIntent(openApp)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    null,
                    getString(R.string.tray_chat),
                    trayAction(ACTION_CHAT),
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    null,
                    getString(R.string.tray_settings),
                    trayAction(ACTION_SETTINGS),
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    null,
                    getString(if (visible) R.string.tray_hide else R.string.tray_show),
                    trayAction(ACTION_TOGGLE),
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    null,
                    getString(R.string.tray_quit),
                    trayAction(ACTION_QUIT),
                ).build()
            )
            .build()
    }

    private fun refreshTrayNotification() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(TRAY_NOTIFICATION_ID, buildTrayNotification())
    }

    /// 显式 notify 事件的气泡通知（独立于常驻托盘）。
    private fun showBubbleNotification(title: String, body: String) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_BUBBLE,
                "桌宠消息",
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        )
        manager.notify(
            BUBBLE_NOTIFICATION_ID,
            Notification.Builder(this, CHANNEL_BUBBLE)
                .setSmallIcon(R.drawable.ic_stat_pet)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .build(),
        )
    }

    private fun invokeTrayAction(action: String) {
        engine?.let {
            MethodChannel(it.dartExecutor.binaryMessenger, CHANNEL_TRAY)
                .invokeMethod("openPanel", action)
        }
    }

    private fun pushScreensChanged() {
        engine?.let {
            MethodChannel(it.dartExecutor.binaryMessenger, CHANNEL_WINDOW)
                .invokeMethod("screensChanged", null)
        }
    }

    // ---------------------------------------------------------------------------
    // 前台应用事件（无障碍）
    // ---------------------------------------------------------------------------

    private fun onAppEvent(event: AccessibilityHub.AppEvent) {
        appSink?.let { pushAppEvent(event) }
    }

    private fun pushAppEvent(event: AccessibilityHub.AppEvent) {
        appSink?.success(
            mapOf(
                "bundleId" to event.packageName,
                "name" to event.label,
                "pid" to 0,
            )
        )
    }

    // ---------------------------------------------------------------------------
    // 退出
    // ---------------------------------------------------------------------------

    /// 与桌面端 quit 同语义：收尾托盘与悬浮窗后结束进程。
    private fun quit() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        android.os.Process.killProcess(android.os.Process.myPid())
    }

    companion object {
        private const val CHANNEL_ENGINE = "dsh_pet/engine"
        private const val CHANNEL_WINDOW = "dsh_pet/window"
        private const val CHANNEL_CONTENT = "dsh_pet/content"
        private const val CHANNEL_INPUT = "dsh_pet/input"
        private const val CHANNEL_TRAY = "dsh_pet/tray"
        private const val CHANNEL_CURSOR = "dsh_pet/cursor"
        private const val CHANNEL_APP = "dsh_pet/app"

        private const val CHANNEL_TRAY_NOTIFICATION = "dsh_pet_tray"
        private const val CHANNEL_BUBBLE = "dsh_pet_bubble"
        private const val TRAY_NOTIFICATION_ID = 1
        private const val BUBBLE_NOTIFICATION_ID = 2

        private const val ACTION_CHAT = "com.dshpet.action.CHAT"
        private const val ACTION_SETTINGS = "com.dshpet.action.SETTINGS"
        private const val ACTION_TOGGLE = "com.dshpet.action.TOGGLE"
        private const val ACTION_QUIT = "com.dshpet.action.QUIT"
    }
}
