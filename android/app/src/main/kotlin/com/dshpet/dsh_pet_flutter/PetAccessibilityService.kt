package com.dshpet.dsh_pet_flutter

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/// 联动无障碍服务：前台应用切换事件 + 读焦点元素正文。
///
/// 对齐桌面端的辅助功能读取（macOS AX / Windows UIA）：
/// 只读不写——不做手势注入、不模拟按键，权限描述里也明说。
class PetAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null || event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val packageName = event.packageName?.toString() ?: return
        // 过滤系统 UI 的面板抖动：没有来源包的事件没有意义。
        if (packageName.isEmpty()) return
        val label = event.className?.toString() ?: packageName
        AccessibilityHub.notify(
            AccessibilityHub.AppEvent(packageName = packageName, label = label)
        )
    }

    override fun onInterrupt() {
        // 读类服务无待中断操作。
    }

    companion object {
        private var instance: PetAccessibilityService? = null

        fun isConnected(): Boolean = instance != null

        /// 前台窗口标题 + 焦点元素文本（输入框 value / 文本节点 selection）。
        /// 结构与桌面端 readFocusedText 一致：{bundleId, title, text}。
        fun readFocusedContent(): Map<String, Any>? {
            val service = instance ?: return null
            val root = service.rootInActiveWindow ?: return null
            val packageName = root.packageName?.toString() ?: ""
            val title = root.window?.title?.toString()?.ifEmpty { packageName } ?: packageName

            val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?: root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
            val text = focused?.text?.toString() ?: ""
            focused?.recycle()
            root.recycle()
            return mapOf(
                "bundleId" to packageName,
                "title" to title,
                "text" to text,
            )
        }
    }
}
