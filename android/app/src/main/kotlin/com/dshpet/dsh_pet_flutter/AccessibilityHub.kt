package com.dshpet.dsh_pet_flutter

/// 无障碍事件总线：PetAccessibilityService（系统回调进程内）与
/// PetOverlayService（Dart 事件流）之间的解耦层。
///
/// 无障碍服务的生命周期由系统设置控制，随时可能断开重连；
/// 订阅方拿到的始终是“最新前台应用”快照 + 后续增量。
object AccessibilityHub {

    data class AppEvent(val packageName: String, val label: String)

    private val listeners = mutableListOf<(AppEvent) -> Unit>()
    private var latestEvent: AppEvent? = null

    fun notify(event: AppEvent) {
        latestEvent = event
        synchronized(listeners) { listeners.toList() }.forEach { it(event) }
    }

    fun latest(): AppEvent? = latestEvent

    fun subscribe(listener: (AppEvent) -> Unit) {
        synchronized(listeners) { listeners.add(listener) }
    }

    fun unsubscribe(listener: (AppEvent) -> Unit) {
        synchronized(listeners) { listeners.remove(listener) }
    }
}
