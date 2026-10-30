import Cocoa
import FlutterMacOS
import UserNotifications

/// 移动者审计：把窗口每次“被谁移动”写进 ~/.dsh_pet_flutter/logs/mover.log。
/// NSLog 的动态串在统一日志里会被隐私重action成 <private>，这里直接落盘拿全文。
enum PetLog {
  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()

  static func append(_ tag: String, _ detail: String) {
    let directory = NSHomeDirectory() + "/.dsh_pet_flutter/logs"
    try? FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    let line = "[\(formatter.string(from: Date()))][\(tag)] \(detail)\n"
    let path = directory + "/mover.log"
    if let handle = FileHandle(forWritingAtPath: path) {
      defer { try? handle.close() }
      handle.seekToEndOfFile()
      if let data = line.data(using: .utf8) {
        handle.write(data)
      }
    } else {
      try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
  }

  /// 必须在移动发生的现场（同一线程）调用才能拿到移动者的调用栈。
  static func stack() -> String {
    Thread.callStackSymbols.joined(separator: "\n    ")
  }
}

class MainFlutterWindow: NSWindow {
  private var bridge: PetBridge?
  private var tray: PetTray?
  private(set) var petFocusable = false

  func setPetFocusable(_ focusable: Bool) {
    petFocusable = focusable
    if focusable {
      ignoresMouseEvents = false
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
      makeKeyAndOrderFront(nil)
    } else {
      NSApp.setActivationPolicy(.accessory)
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()

    // FlutterView 实例化时会把自身背景写死为黑色（见 FlutterViewController.h 的
    // backgroundColor 说明）：只清 layer 颜色不够，必须清这个属性，否则整窗被涂黑。
    flutterViewController.backgroundColor = NSColor.clear
    flutterViewController.view.wantsLayer = true
    flutterViewController.view.layer?.isOpaque = false
    flutterViewController.view.layer?.backgroundColor = NSColor.clear.cgColor

    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 桌宠不需要抢焦点：点了宠物也不该把用户正在用的编辑器切走。
    // 代价是窗口内无法打字，所以对话输入走“投递到关联软件”的链路。
    self.styleMask = [.borderless]
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.isReleasedWhenClosed = false
    // 状态恢复会把上个会话的窗口 frame 原样搬回来，跨屏并集会被旧坐标顶掉。
    self.isRestorable = false

    bridge = PetBridge(
      window: self,
      messenger: flutterViewController.engine.binaryMessenger,
      focusHandler: { [weak self] focusable in
        self?.setPetFocusable(focusable)
      }
    )
    bridge?.install()

    // 托盘（菜单栏图标）是桌宠唯一的“没有贴纸”入口：窗口全屏透明且不可见边界，
    // 用户需要一条能确定找到的路径来显示/隐藏宠物、打开对话或设置、退出。
    let petTray = PetTray(
      window: self,
      messenger: flutterViewController.engine.binaryMessenger
    )
    petTray.install()
    tray = petTray

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    NSLog("[pet] MainFlutterWindow awakeFromNib 完成，isVisible=\(self.isVisible)")
    PetLog.append("boot", "awakeFromNib 完成 frame=\(frame)")

    // 移动者审计：frame 入口的否决只能拦“经 NSWindow API 的进程内移动”，
    // 进程外（WindowServer 直改 frame）不经过任何入口，只能在 didMove 里当场
    // 发现并铺回。两种情况都把调用栈写进 mover.log 留证。
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(petWindowDidMove(_:)),
      name: NSWindow.didMoveNotification, object: self)
    center.addObserver(
      self, selector: #selector(petWindowDidChangeScreen(_:)),
      name: NSWindow.didChangeScreenNotification, object: self)
    center.addObserver(
      self, selector: #selector(petAppActiveChanged(_:)),
      name: NSApplication.didBecomeActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(petAppActiveChanged(_:)),
      name: NSApplication.didResignActiveNotification, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override var canBecomeKey: Bool { petFocusable }
  override var canBecomeMain: Bool { petFocusable }

  /// AppKit 激活应用时会把“标题栏不在主屏”的窗口拖回主屏附近（constrainFrameRect），
  /// 桌宠窗口刻意铺满多屏并集，被这么一拉就只剩外接屏部分、MacBook 屏全空白——
  /// 这就是“跨屏拖不动”的根因。桌宠窗口永远铺满所有屏，禁用一切约束。
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  // MARK: - 移动者否决门

  /// 窗口的唯一合法 frame = 当前活动屏的可见区。
  ///
  /// 为什么不再铺满所有屏的并集：一个窗口横跨 Retina(2x) 与普通屏(1x) 时，
  /// 窗口服务器只按一块屏的 backing scale 合成，主屏上会整块不显示（实测）。
  /// 单屏窗口既解决“宠物不显示”，也让菜单/面板永远不会被送到屏缝里。
  private func activeScreenIfDeviant(_ rect: NSRect) -> NSRect? {
    guard let active = PetBridge.activeScreenFrame() else { return nil }
    let deviates = abs(rect.minX - active.minX) > 1
      || abs(rect.minY - active.minY) > 1
      || abs(rect.width - active.width) > 1
      || abs(rect.height - active.height) > 1
    return deviates ? active : nil
  }

  private func vetoForeignMove(_ entry: String, requested: NSRect, active: NSRect) {
    PetLog.append(
      "veto",
      "入口=\(entry) 请求=\(requested) 活动屏=\(active) active=\(NSApp.isActive)\n"
        + "栈：\n    " + PetLog.stack())
  }

  override func setFrameOrigin(_ origin: NSPoint) {
    let target = NSRect(origin: origin, size: frame.size)
    if let active = activeScreenIfDeviant(target) {
      vetoForeignMove("setFrameOrigin", requested: target, active: active)
      return
    }
    super.setFrameOrigin(origin)
  }

  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    if let active = activeScreenIfDeviant(frameRect) {
      vetoForeignMove("setFrame", requested: frameRect, active: active)
      return
    }
    super.setFrame(frameRect, display: flag)
  }

  override func setFrame(
    _ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool
  ) {
    if let active = activeScreenIfDeviant(frameRect) {
      vetoForeignMove("setFrame:animate", requested: frameRect, active: active)
      return
    }
    super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
  }

  /// 进程外移动者绕过一切 frame 入口，didMove 是最后的发现点：当场铺回活动屏。
  @objc private func petWindowDidMove(_ note: Notification) {
    let current = frame
    guard let active = activeScreenIfDeviant(current) else { return }
    PetLog.append(
      "didMove-foreign",
      "frame=\(current) 活动屏=\(active) active=\(NSApp.isActive)\n"
        + "栈：\n    " + PetLog.stack())
    PetBridge.applyActiveScreen(to: self)
  }

  @objc private func petWindowDidChangeScreen(_ note: Notification) {
    PetLog.append(
      "changeScreen",
      "frame=\(frame) screen=\(String(describing: screen)) active=\(NSApp.isActive)")
  }

  @objc private func petAppActiveChanged(_ note: Notification) {
    PetLog.append("appActive", "\(note.name.rawValue) active=\(NSApp.isActive)")
  }
}


/// 菜单栏托盘：桌宠没有可见窗口边框，托盘是用户能可靠找到的入口。
final class PetTray: NSObject, NSMenuDelegate {
  private let window: NSWindow
  private let channel: FlutterMethodChannel
  private var statusItem: NSStatusItem?
  private weak var toggleItem: NSMenuItem?

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    self.channel = FlutterMethodChannel(
      name: "dsh_pet/tray", binaryMessenger: messenger)
    super.init()
  }

  func install() {
    // 常驻菜单栏：没有 Dock 图标，避免用户误以为桌宠是个普通前台应用。
    NSApp.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.toolTip = "桌宠 · 右键菜单"
      // 工程部署目标低于 11.0，SF Symbol 需要可用性守卫；旧系统用文字兜底。
      if #available(macOS 11.0, *) {
        let icon = NSImage(
          systemSymbolName: "pawprint.fill", accessibilityDescription: "桌宠")
        icon?.isTemplate = true
        button.image = icon
      } else {
        button.title = "🐾"
      }
    }
    let menu = buildMenu()
    // 文案/图标跟随窗口真实状态：/window/* 诊断端点也能改可见性，
    // 本地标志位会漂移，每次展开时刷新是唯一不撒谎的做法。
    menu.delegate = self
    item.menu = menu
    statusItem = item
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    // 第一项永远是“藏/放”：黑话最少，用户第一眼能找到宠物。
    let toggle = makeItem(
      "隐藏宠物", #selector(toggleVisible), symbol: "eye.slash")
    menu.addItem(toggle)
    toggleItem = toggle

    menu.addItem(.separator())
    menu.addItem(
      makeItem(
        "打开对话框", #selector(openChat), key: "\r",
        modifiers: [.command], symbol: "bubble.left.and.bubble.right"))
    menu.addItem(
      makeItem(
        "打开设置", #selector(openSettings), key: ",",
        modifiers: [.command], symbol: "gearshape"))
    menu.addItem(.separator())
    menu.addItem(
      makeItem(
        "退出桌宠", #selector(quit), key: "q",
        modifiers: [.command], symbol: "power"))
    return menu
  }

  private func makeItem(
    _ title: String, _ action: Selector, key: String = "",
    modifiers: NSEvent.ModifierFlags = [], symbol: String? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    if !key.isEmpty {
      item.keyEquivalentModifierMask = modifiers
    }
    if let symbol {
      item.image = symbolImage(symbol, accessibility: title)
    }
    return item
  }

  /// SF Symbol 统一走模板图，深浅色菜单栏都会自动反色。
  private func symbolImage(_ name: String, accessibility: String) -> NSImage? {
    guard #available(macOS 11.0, *) else { return nil }
    let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibility)
    image?.isTemplate = true
    return image
  }

  /// 每次展开菜单都按窗口真实状态改文案与图标（见 install 里的说明）。
  func menuNeedsUpdate(_ menu: NSMenu) {
    let visible = window.isVisible
    toggleItem?.title = visible ? "隐藏宠物" : "显示宠物"
    toggleItem?.image = symbolImage(
      visible ? "eye.slash" : "eye",
      accessibility: visible ? "隐藏宠物" : "显示宠物")
    // 隐藏时两个面板项仍然可用：打开面板会顺带把窗口拉回来。
  }

  @objc private func toggleVisible() {
    NSLog("[pet] 托盘切换可见性，切换前 isVisible=\(window.isVisible)")
    PetBridge.setVisible(!window.isVisible, window: window)
  }

  // 面板要能打字，交给 Dart 侧统一处理（它会先显示窗口，再临时切回 regular 并激活）。
  @objc private func openChat() {
    channel.invokeMethod("openPanel", arguments: "chat")
  }

  @objc private func openSettings() {
    channel.invokeMethod("openPanel", arguments: "settings")
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}

/// macOS 原生能力桥：窗口穿透、全局光标、前台应用、窗口正文读取、按键注入。
///
/// 为什么全部放在一个文件：这些能力共享同一套授权前提（辅助功能）与同一个窗口对象，
/// 分散到多个文件反而让人看不清“哪一步需要用户授权”。UI 与业务逻辑仍分层：
/// 本文件只有平台能力，命中区判定、状态聚合、联动规则都在 Dart 侧。
final class PetBridge {
  private let window: NSWindow
  private let messenger: FlutterBinaryMessenger
  private let focusHandler: (Bool) -> Void
  private var windowChannel: FlutterMethodChannel?
  private var cursorTimer: Timer?
  private var cursorChannel: FlutterEventChannel?
  private var appChannel: FlutterEventChannel?
  private var cursorSink: FlutterEventSink?
  private var appSink: FlutterEventSink?
  private var screenObserver: NSObjectProtocol?
  private var frameWatchTimer: Timer?
  private var lastCursor: NSPoint = NSPoint(x: -1, y: -1)
  private var lastMouseDown = false

  init(window: NSWindow, messenger: FlutterBinaryMessenger, focusHandler: @escaping (Bool) -> Void) {
    self.window = window
    self.messenger = messenger
    self.focusHandler = focusHandler
  }

  func install() {
    configureWindow()
    installMethodChannels()
    installEventChannels()
    startCursorMonitor()
    startAppWatch()
    startFrameWatchdog()
  }

  deinit {
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
    cursorTimer?.invalidate()
    frameWatchTimer?.invalidate()
  }

  // MARK: - 窗口形态

  private func configureWindow() {
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.level = .statusBar
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    window.isMovableByWindowBackground = false
    window.acceptsMouseMovedEvents = true
    // 默认整窗穿透：只有光标落在宠物身体/气泡/菜单上时才由 Dart 翻转。
    window.ignoresMouseEvents = true
    PetBridge.applyActiveScreen(to: window)
    // 屏幕热插拔/分辨率变化后必须重铺窗口，否则宠物会被旧边界卡住。
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      // 拔掉活动屏后下标越界：退回主屏，别让窗口贴在已消失的坐标上。
      if PetBridge.activeScreenIndex >= NSScreen.screens.count {
        PetBridge.activeScreenIndex = 0
      }
      PetBridge.applyActiveScreen(to: self.window)
      self.pushScreens()
    }
  }

  /// 当前活动屏的下标（NSScreen.screens 顺序，0 = 系统主屏）。
  /// 单屏窗口一次只覆盖一块屏；拖到另一块屏时由 Dart 调 moveToScreen 换屏。
  static var activeScreenIndex = 0

  /// 当前活动屏的可见区；没有屏幕时返回 nil（调用方各自决定兜底）。
  static func activeScreenFrame() -> NSRect? {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return nil }
    let index = min(max(activeScreenIndex, 0), screens.count - 1)
    return screens[index].visibleFrame
  }

  /// 窗口铺满“当前活动屏的可见区”。
  /// 不再跨屏铺并集：混合 DPI 下跨屏窗口在主屏不合成（见 MainFlutterWindow 注释）。
  static func applyActiveScreen(to window: NSWindow) {
    guard let active = activeScreenFrame() else { return }
    window.setFrame(active, display: true)
    // setFrame 后 frame 若≠请求值，说明有东西在改写窗口位置
    NSLog("[pet] applyActiveScreen 请求=\(active) 结果=\(window.frame)")
  }

  /// 显示/隐藏窗口的唯一路径：托盘与 /window/* 诊断端点共用，
  /// 避免两处实现漂移出“托盘能恢复、curl 不能”这类分叉行为。
  /// NSLog 进统一日志：不随 stdout 缓冲丢，事后可 `log show` 追查。
  static func setVisible(_ visible: Bool, window: NSWindow) {
    if visible {
      // 隐藏期间屏幕布局可能变化（外接屏热插拔），旧 frame 可能把窗口
      // 放回“没有显示器”的位置；先重铺活动屏再拉回前台。
      applyActiveScreen(to: window)
      window.orderFrontRegardless()
      // 个别情况下 accessory 应用需要一次激活才能把窗口拉回屏上；
      // 只在确实没显示时补一击，避免每次都抢用户焦点。
      if !window.isVisible {
        NSApp.activate(ignoringOtherApps: false)
        window.orderFrontRegardless()
      }
    } else {
      window.orderOut(nil)
    }
    NSLog("[pet] setVisible(\(visible)) -> isVisible=\(window.isVisible)")
  }

  /// 屏幕可见区列表（窗口本地坐标，主屏排最前）：宠物用它找“最近的真实屏幕”。
  ///
  /// 这里必须用 `NSScreen.screens` 的顺序：它按系统“主显示器”排序。
  /// 之前按 `NSScreen.main` 排序，而 main 是“当前焦点窗口所在屏”，会随用户
  /// 点击外接屏上的窗口漂移，导致桌宠出生在外接屏、主屏上什么都看不到。
  private func screenRects() -> [[String: Any]] {
    let frame = window.frame
    let primary = NSScreen.screens.first
    let activeIndex = PetBridge.activeScreenIndex
    return NSScreen.screens.enumerated().map { index, screen in
      let visible = screen.visibleFrame
      return [
        "x": visible.minX - frame.minX,
        "y": frame.maxY - visible.maxY,
        "width": visible.width,
        "height": visible.height,
        "index": index,
        "primary": screen === primary,
        "active": index == activeIndex,
      ]
    }
  }

  private func pushScreens() {
    windowChannel?.invokeMethod("screensChanged", arguments: nil)
  }

  /// 进程视角的完整窗口/屏幕状态：多屏错位时用来对照真实布局，
  /// 直接回答“应用看到的坐标体系”是否与系统一致。
  private func windowDiagnostics() -> [String: Any] {
    let windowFrame = window.frame
    let screens = NSScreen.screens.map { screen -> [String: Any] in
      let visible = screen.visibleFrame
      return [
        "x": Double(visible.minX),
        "y": Double(visible.minY),
        "width": Double(visible.width),
        "height": Double(visible.height),
        "isMain": screen === NSScreen.main,
      ]
    }
    var state: [String: Any] = [
      "visible": window.isVisible,
      "frame": [
        "x": Double(windowFrame.minX),
        "y": Double(windowFrame.minY),
        "width": Double(windowFrame.width),
        "height": Double(windowFrame.height),
      ],
      "screens": screens,
    ]
    state["activeScreenIndex"] = PetBridge.activeScreenIndex
    if let active = PetBridge.activeScreenFrame() {
      state["activeScreen"] = [
        "x": Double(active.minX),
        "y": Double(active.minY),
        "width": Double(active.width),
        "height": Double(active.height),
      ]
      // 兼容旧诊断脚本：union 现在就是活动屏，不再是所有屏并集。
      state["union"] = state["activeScreen"]
    }
    return state
  }

  // MARK: - 方法通道

  private func installMethodChannels() {
    let channel = FlutterMethodChannel(
      name: "dsh_pet/window", binaryMessenger: messenger)
    windowChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "setInteractive":
        let interactive = (call.arguments as? Bool) ?? false
        // 穿透 = 不接收鼠标；置顶窗口在拉伸/移动后仍要保持该状态
        self.window.ignoresMouseEvents = !interactive
        print("[pet] setInteractive -> \(interactive)")
        result(nil)
      case "setAlwaysOnTop":
        let onTop = (call.arguments as? Bool) ?? true
        self.window.level = onTop ? .statusBar : .normal
        result(nil)
      case "showWindow":
        PetBridge.setVisible(true, window: self.window)
        result(self.window.isVisible)
      case "hideWindow":
        PetBridge.setVisible(false, window: self.window)
        result(self.window.isVisible)
      case "isVisible":
        result(self.window.isVisible)
      case "windowState":
        result(self.windowDiagnostics())
      case "getScreens":
        result(self.screenRects())
      case "moveToScreen":
        // 单屏窗口换屏：拖过屏幕边缘时由 Dart 指定目标屏。
        // 返回新窗口尺寸与“指针在新窗口里的本地坐标”，Dart 立刻把宠物放回
        // 指针下方，避免换屏那一帧宠物被旧坐标甩到屏外。
        guard let args = call.arguments as? [String: Any],
          let rawIndex = args["index"] as? Int
        else {
          result(FlutterError(code: "window.bad-index", message: "缺少 screen index", details: nil))
          return
        }
        let screens = NSScreen.screens
        guard rawIndex >= 0, rawIndex < screens.count else {
          result(
            FlutterError(
              code: "window.bad-index", message: "屏幕下标越界：\(rawIndex)", details: nil))
          return
        }
        PetBridge.activeScreenIndex = rawIndex
        let target = screens[rawIndex].visibleFrame
        self.window.setFrame(target, display: true)
        self.pushScreens()
        let point = NSEvent.mouseLocation
        let local = NSPoint(x: point.x - target.minX, y: target.maxY - point.y)
        result([
          "index": rawIndex,
          "width": Double(target.width),
          "height": Double(target.height),
          "pointer": ["x": Double(local.x), "y": Double(local.y)],
        ])
      case "setFocusable":
        // 打开设置/对话面板时要能接收键盘输入，否则 Flutter 文本框永远拿不到焦点。
        // 穿透状态只由 Dart 的命中判定决定：这里再强制写一次会和关闭面板后
        // 的 setInteractive 抢时序，出现“面板关了但整窗还在吞点击”的假象。
        let focusable = (call.arguments as? Bool) ?? false
        self.focusHandler(focusable)
        result(nil)
      case "quit":
        NSApp.terminate(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let contentChannel = FlutterMethodChannel(
      name: "dsh_pet/content", binaryMessenger: messenger)
    contentChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "readFocusedText":
        result(PetBridge.readFocusedWindow())
      case "isTrusted":
        result(AXIsProcessTrusted())
      case "requestTrust":
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        result(AXIsProcessTrustedWithOptions(options))
      case "notify":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "notify.bad-args", message: "缺少通知内容", details: nil))
          return
        }
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (args["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let center = UNUserNotificationCenter.current()
        // 通知回调可能在后台队列；MethodChannel 的 result 必须回主线程。
        func finish(_ value: Any?) {
          DispatchQueue.main.async { result(value) }
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
          guard granted, error == nil else {
            finish(
              FlutterError(
                code: "notify.denied",
                message: error?.localizedDescription ?? "系统通知权限未开启",
                details: nil))
            return
          }
          let content = UNMutableNotificationContent()
          content.title = (title?.isEmpty == false ? title! : "桌宠")
          content.body = (body?.isEmpty == false ? body! : "有新的消息")
          content.sound = .default
          let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
          center.add(request) { addError in
            if let addError {
              finish(
                FlutterError(
                  code: "notify.failed", message: addError.localizedDescription, details: nil))
            } else {
              finish(nil)
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let inputChannel = FlutterMethodChannel(
      name: "dsh_pet/input", binaryMessenger: messenger)
    inputChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "activateApp":
        guard let args = call.arguments as? [String: Any],
          let bundleId = args["bundleId"] as? String
        else {
          result(
            FlutterError(code: "input.bad-args", message: "缺少 bundleId", details: nil))
          return
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard let app = apps.first else {
          result(
            FlutterError(
              code: "input.app-not-running", message: "应用未运行：\(bundleId)", details: nil))
          return
        }
        result(app.activate(options: [.activateIgnoringOtherApps]))
      case "pasteAndSubmit":
        result(PetBridge.pasteAndSubmit())
      case "openUrl":
        guard let args = call.arguments as? [String: Any],
          let raw = args["url"] as? String, let url = URL(string: raw)
        else {
          result(FlutterError(code: "input.bad-url", message: "URL 非法", details: nil))
          return
        }
        result(NSWorkspace.shared.open(url))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - 事件通道

  private func installEventChannels() {
    cursorChannel = FlutterEventChannel(
      name: "dsh_pet/cursor", binaryMessenger: messenger)
    let cursorHandler = StreamHandler()
    cursorHandler.onListen = { [weak self] sink in self?.cursorSink = sink }
    cursorHandler.onCancel = { [weak self] in self?.cursorSink = nil }
    cursorChannel?.setStreamHandler(cursorHandler)

    appChannel = FlutterEventChannel(name: "dsh_pet/app", binaryMessenger: messenger)
    let appHandler = StreamHandler()
    appHandler.onListen = { [weak self] sink in
      self?.appSink = sink
      if let front = NSWorkspace.shared.frontmostApplication {
        sink(PetBridge.appInfo(front))
      }
    }
    appHandler.onCancel = { [weak self] in self?.appSink = nil }
    appChannel?.setStreamHandler(appHandler)
  }

  private func startCursorMonitor() {
    // 轮询 mouseLocation 不需要任何系统授权；CGEventTap 才需要“输入监控”，这里刻意避开。
    // 同时上报左键按下状态：拖过屏幕边缘换窗后 Flutter 的 pan 可能被系统取消，
    // Dart 需要靠这条全局流继续拖动并在松开时收尾。
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      guard let self, let sink = self.cursorSink else { return }
      let point = NSEvent.mouseLocation
      let frame = self.window.frame
      let local = NSPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
      let down = (NSEvent.pressedMouseButtons & 0x1) != 0
      if abs(local.x - self.lastCursor.x) < 1 && abs(local.y - self.lastCursor.y) < 1
        && down == self.lastMouseDown {
        return
      }
      self.lastCursor = local
      self.lastMouseDown = down
      sink(["x": Double(local.x), "y": Double(local.y), "down": down])
    }
    RunLoop.main.add(timer, forMode: .common)
    cursorTimer = timer
  }

  private func startAppWatch() {
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleActivation(_:)),
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil
    )
  }

  /// frame 看门狗（末道防线）：主防御在 MainFlutterWindow 的 frame 否决门，
  /// 这里仍 1Hz 对账，专拦绕过 NSWindow API 的进程外移动与未来新增的挪窗者。
  private func startFrameWatchdog() {
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      guard let self, let active = PetBridge.activeScreenFrame() else { return }
      let frame = self.window.frame
      if abs(frame.minX - active.minX) > 1 || abs(frame.minY - active.minY) > 1
        || abs(frame.width - active.width) > 1 || abs(frame.height - active.height) > 1 {
        NSLog("[pet] frame 漂移被看门狗纠正：\(frame) -> \(active)")
        self.window.setFrame(active, display: true)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    frameWatchTimer = timer
  }

  @objc private func handleActivation(_ note: Notification) {
    guard let sink = appSink,
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    else { return }
    sink(PetBridge.appInfo(app))
  }

  private static func appInfo(_ app: NSRunningApplication) -> [String: Any] {
    [
      "bundleId": app.bundleIdentifier ?? "",
      "name": app.localizedName ?? "",
      "pid": Int(app.processIdentifier),
    ]
  }

  // MARK: - 内容读取（辅助功能）

  private static func readFocusedWindow() -> Any {
    guard AXIsProcessTrusted() else {
      return FlutterError(
        code: "ax.denied",
        message: "未获得“辅助功能”授权，无法读取前台窗口正文",
        details: nil)
    }
    guard let front = NSWorkspace.shared.frontmostApplication else {
      return FlutterError(code: "ax.no-front", message: "没有前台应用", details: nil)
    }
    let appElement = AXUIElementCreateApplication(front.processIdentifier)
    var windowRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
      == .success, let windowValue = windowRef
    else {
      return FlutterError(code: "ax.no-window", message: "前台窗口不可读", details: nil)
    }
    let windowElement = windowValue as! AXUIElement

    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
    let title = titleRef as? String ?? ""

    var focusedRef: CFTypeRef?
    AXUIElementCopyAttributeValue(windowElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
    var text = ""
    if let focusedValue = focusedRef {
      let focusedElement = focusedValue as! AXUIElement
      var valueRef: CFTypeRef?
      AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &valueRef)
      if let value = valueRef as? String {
        text = value
      }
      var selectedRef: CFTypeRef?
      AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedRef)
      if let selected = selectedRef as? String, !selected.isEmpty {
        text = selected
      }
    }

    return ["bundleId": front.bundleIdentifier ?? "", "title": title, "text": text]
  }

  // MARK: - 按键注入

  private static func pasteAndSubmit() -> Any {
    guard AXIsProcessTrusted() else {
      return FlutterError(
        code: "input.denied",
        message: "未获得“辅助功能”授权，无法向其他应用发送按键",
        details: nil)
    }
    let source = CGEventSource(stateID: .hidSystemState)
    // ⌘V
    let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
    let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    vDown?.flags = .maskCommand
    vUp?.flags = .maskCommand
    vDown?.post(tap: .cghidEventTap)
    vUp?.post(tap: .cghidEventTap)

    // 等目标应用消费完粘贴再回车，否则可能贴到上一帧的位置
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
      let returnDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
      let returnUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
      returnDown?.post(tap: .cghidEventTap)
      returnUp?.post(tap: .cghidEventTap)
    }
    return true
  }
}

/// Flutter EventChannel 的 Swift 侧回调容器。
final class StreamHandler: NSObject, FlutterStreamHandler {
  // sink 需要在 onListen 返回后继续被持有（定时器里回调），因此参数必须是 escaping。
  var onListen: ((@escaping FlutterEventSink) -> Void)?
  var onCancel: (() -> Void)?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    onListen?(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancel?()
    return nil
  }
}
