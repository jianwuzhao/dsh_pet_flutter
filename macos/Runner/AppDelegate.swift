import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 桌宠常驻菜单栏：托盘“隐藏宠物”把唯一窗口 orderOut 后，系统会把它当
    // “最后一扇窗已关闭”，这里返回 true 会连托盘图标一起退出整个应用。
    return false
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 后台启动（nohup / 开机自启）不激活应用，AppKit 也就不会把 nib 窗口拉上屏：
    // 窗口从启动起就是 orderOut 状态——这就是“宠物不显示”的根因，这里显式兜底。
    let window = NSApp.windows.first { $0 is MainFlutterWindow }
    NSLog("[pet] applicationDidFinishLaunching，isVisible=\(window?.isVisible ?? false)")
    window?.orderFrontRegardless()
    // LaunchServices 激活可能在启动序里重排窗口，完成启动后再铺一次活动屏兜底。
    if let petWindow = window as? MainFlutterWindow {
      PetBridge.applyActiveScreen(to: petWindow)
    }
    NSLog("[pet] 启动兜底 orderFront 后 isVisible=\(window?.isVisible ?? false)")
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
