#ifndef RUNNER_PET_BRIDGE_H_
#define RUNNER_PET_BRIDGE_H_

#include <flutter/event_channel.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

// 桌宠 Windows 原生能力桥：窗口形态（无边框/透明/置顶/穿透）、托盘、
// 多屏枚举与换屏、全局光标流、前台应用监听、正文读取（UIA）、按键注入。
//
// 与 macOS 侧 MainFlutterWindow.swift 的 PetBridge 一一对应：
// 通道名、方法名、参数与返回结构完全一致，Dart 侧无需感知平台差异。
class PetBridge {
 public:
  PetBridge(HWND window, flutter::FlutterViewController* controller);
  ~PetBridge();

  // 注册通道、托盘、事件钩子，并把窗口摆成桌宠形态。必须在窗口创建后调用。
  void Install();

  // WM_DISPLAYCHANGE / WM_DPICHANGED / WM_DEVICECHANGE 到达时调用：
  // 重铺活动屏并推送 screensChanged。
  void OnDisplayChanged();

  // 托盘消息（WM_APP_TRAY）与菜单命令（WM_COMMAND）到达时调用。
  // 返回 true 表示消息已消费，不再向下传递。
  bool HandleTrayMessage(UINT const message, WPARAM const wparam,
                         LPARAM const lparam);

  // WM_TIMER 到达时调用（光标轮询 / 粘贴后的回车补发）。已消费返回 true。
  bool HandleTimer(UINT_PTR const timer_id);

  // 屏幕工作区（物理像素）：work = 不含任务栏的工作区，full = 整屏。
  // 公开是因为屏幕枚举回调（cpp 侧）需要具名构造它。
  struct MonitorInfo {
    RECT work;
    RECT full;
    bool primary;
  };

 private:
  // 注册全部 MethodChannel / EventChannel。
  void InstallMethodChannels();
  void InstallEventChannels();

  // ---------------------------------------------------------------------------
  // 窗口形态
  // ---------------------------------------------------------------------------

  // 当前窗口所在显示器的 DPI 缩放（96 基准）：物理像素 <-> Flutter 逻辑像素。
  double WindowScale() const;

  // 活动屏下标（主屏排最前的枚举顺序，0 = 主屏）。
  static int active_screen_index_;

  // 把窗口铺满当前活动屏的工作区（不含任务栏）。
  void ApplyActiveScreen();

  // 显示/隐藏窗口的唯一路径：托盘与 /window/* 诊断端点共用。
  void SetVisible(bool visible);

  static std::vector<PetBridge::MonitorInfo> EnumMonitorsSorted();

  // getScreens 返回值：窗口本地逻辑坐标的屏幕列表（主屏排最前）。
  flutter::EncodableValue ScreenRects();

  // 进程视角的完整窗口/屏幕状态（多屏错位对账用）。
  flutter::EncodableMap WindowDiagnostics();

  // ---------------------------------------------------------------------------
  // 内容读取（UIA）与按键注入
  // ---------------------------------------------------------------------------

  // 读前台窗口标题 + 焦点元素正文/选区，失败时返回带 code 的错误 map。
  // 返回值是 {bundleId, title, text} 或 {"error", "code", "message"}。
  flutter::EncodableMap ReadFocusedWindow();

  // Ctrl+V 粘贴，180ms 后补回车（SetTimer 在主线程消息循环里执行）。
  bool PasteAndSubmit();

  // 按 exe 名（约定 = Dart 侧 bundleId，如 Trae.exe）找窗口并拉到前台。
  bool ActivateApp(const std::string& exe_name);

  // ---------------------------------------------------------------------------
  // 托盘
  // ---------------------------------------------------------------------------

  void InstallTray();
  void ShowTrayMenu();

  // ---------------------------------------------------------------------------
  // 成员
  // ---------------------------------------------------------------------------

  HWND window_;
  flutter::FlutterViewController* controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      content_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> input_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;

  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      cursor_event_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      app_event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> cursor_sink_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> app_sink_;

  NOTIFYICONDATAW tray_{};
  bool tray_added_ = false;
  bool focusable_ = false;

  // 前台应用切换钩子。
  void* win_event_hook_ = nullptr;

  // 把前台窗口的应用信息（exe 名/pid）推给 Dart 的 app 事件流。
  void PushAppEvent(HWND hwnd);

  // 光标轮询去重（窗口本地逻辑坐标 + 左键状态）。
  double last_cursor_x_ = -1;
  double last_cursor_y_ = -1;
  bool last_mouse_down_ = false;
};

#endif  // RUNNER_PET_BRIDGE_H_
