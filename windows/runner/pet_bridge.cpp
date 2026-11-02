#include "pet_bridge.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <shellapi.h>
#include <uiautomation.h>

#include <algorithm>
#include <cmath>
#include <utility>

#include "resource.h"

namespace {

// 光标轮询（~60Hz，与 macOS 侧一致）与粘贴后补回车的定时器 ID。
constexpr UINT_PTR kCursorTimerId = 1;
constexpr UINT_PTR kPasteEnterTimerId = 2;
constexpr UINT kCursorTimerMs = 16;
constexpr UINT kPasteEnterDelayMs = 180;

// 托盘回调消息与菜单命令 ID。
constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT_PTR kMenuToggle = 2001;
constexpr UINT_PTR kMenuChat = 2002;
constexpr UINT_PTR kMenuSettings = 2003;
constexpr UINT_PTR kMenuQuit = 2004;

// 单实例：桌宠进程只有一个顶层窗口，WinEventProc 静态回调借它转发。
PetBridge* g_instance = nullptr;

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                       static_cast<int>(wide.size()), nullptr,
                                       0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string utf8(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                      &utf8[0], size, nullptr, nullptr);
  return utf8;
}

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                       static_cast<int>(utf8.size()), nullptr,
                                       0);
  if (size <= 0) return {};
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      &wide[0], size);
  return wide;
}

std::wstring ToLowerWide(std::wstring text) {
  std::transform(text.begin(), text.end(), text.begin(),
                 [](wchar_t ch) { return static_cast<wchar_t>(towlower(ch)); });
  return text;
}

// 取路径里的文件名（如 C:\...\Trae.exe -> Trae.exe），用于 bundleId 匹配。
std::wstring FileNameOf(const std::wstring& path) {
  const size_t pos = path.find_last_of(L"\\/");
  return pos == std::wstring::npos ? path : path.substr(pos + 1);
}

std::wstring ExeNameForPid(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return L"";
  wchar_t path[MAX_PATH];
  DWORD size = MAX_PATH;
  std::wstring name;
  if (QueryFullProcessImageNameW(process, 0, path, &size) && size > 0) {
    name = FileNameOf(std::wstring(path, size));
  }
  CloseHandle(process);
  return name;
}

// SetForegroundWindow 有前台锁定（只有前台进程能成功）：临时把输入队列
// 挂到当前前台线程再切，是跨进程激活窗口的标准做法。
void ForceSetForeground(HWND target) {
  const HWND foreground = GetForegroundWindow();
  const DWORD foreground_tid = GetWindowThreadProcessId(foreground, nullptr);
  const DWORD current_tid = GetCurrentThreadId();
  if (foreground_tid != 0) {
    AttachThreadInput(current_tid, foreground_tid, TRUE);
  }
  SetForegroundWindow(target);
  BringWindowToTop(target);
  SetFocus(target);
  if (foreground_tid != 0) {
    AttachThreadInput(current_tid, foreground_tid, FALSE);
  }
}

struct FindWindowContext {
  std::wstring target_exe;
  HWND found = nullptr;
};

// 按进程 exe 名找可见顶层窗口：桌宠右键"打开关联软件"用它唤起 Trae 等。
BOOL CALLBACK FindWindowByExe(HWND hwnd, LPARAM lparam) {
  auto* context = reinterpret_cast<FindWindowContext*>(lparam);
  if (!IsWindowVisible(hwnd)) return TRUE;
  if (GetWindowLongPtr(hwnd, GWL_STYLE) & WS_CHILD) return TRUE;
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid != 0 && ExeNameForPid(pid) == context->target_exe) {
    context->found = hwnd;
    return FALSE;
  }
  return TRUE;
}

BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC, RECT*, LPARAM lparam) {
  auto* monitors = reinterpret_cast<std::vector<PetBridge::MonitorInfo>*>(
      lparam);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (GetMonitorInfoW(monitor, &info)) {
    monitors->push_back(PetBridge::MonitorInfo{
        info.rcWork, info.rcMonitor, (info.dwFlags & MONITORINFOF_PRIMARY) != 0});
  }
  return TRUE;
}

}  // namespace

int PetBridge::active_screen_index_ = 0;

PetBridge::PetBridge(HWND window, flutter::FlutterViewController* controller)
    : window_(window), controller_(controller) {}

PetBridge::~PetBridge() {
  if (win_event_hook_ != nullptr) {
    UnhookWinEvent(reinterpret_cast<HWINEVENTHOOK>(win_event_hook_));
    win_event_hook_ = nullptr;
  }
  if (tray_added_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_);
    tray_added_ = false;
  }
  KillTimer(window_, kCursorTimerId);
  KillTimer(window_, kPasteEnterTimerId);
  if (g_instance == this) g_instance = nullptr;
}

void PetBridge::Install() {
  g_instance = this;

  // 桌宠窗口形态：无边框 + 分层透明 + 不进任务栏 + 默认整窗穿透、不抢焦点。
  // Flutter engine 检测到 WS_EX_LAYERED 后启用带 alpha 的合成，透明由 Dart
  // 侧画布自带；穿透用 WS_EX_TRANSPARENT 切换（对应 setInteractive）。
  LONG_PTR style = GetWindowLongPtr(window_, GWL_STYLE);
  SetWindowLongPtr(window_, GWL_STYLE,
                   (style & ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW)) |
                       WS_POPUP);
  LONG_PTR ex_style = GetWindowLongPtr(window_, GWL_EXSTYLE);
  SetWindowLongPtr(window_, GWL_EXSTYLE,
                   ex_style | WS_EX_LAYERED | WS_EX_TOOLWINDOW |
                       WS_EX_TRANSPARENT | WS_EX_NOACTIVATE);
  SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);

  ApplyActiveScreen();
  InstallMethodChannels();
  InstallEventChannels();
  InstallTray();

  // 光标轮询：GetCursorPos 不需要任何授权，与 macOS 侧刻意避开 CGEventTap
  // 的思路一致；跨屏换窗拖动时 Dart 靠这条全局流续拖。
  SetTimer(window_, kCursorTimerId, kCursorTimerMs, nullptr);

  // 前台应用监听：EVENT_SYSTEM_FOREGROUND 的 out-of-context 钩子在主线程
  // 消息循环里回调，EventSink 恰好也只允许平台线程使用。
  win_event_hook_ = reinterpret_cast<void*>(SetWinEventHook(
      EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
      [](HWINEVENTHOOK, DWORD, HWND hwnd, LONG, LONG, DWORD, DWORD) {
        if (g_instance != nullptr) g_instance->PushAppEvent(hwnd);
      },
      0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS));

  // 出生即显示但不抢用户正在用的窗口焦点。
  ShowWindow(window_, SW_SHOWNOACTIVATE);
}

// ---------------------------------------------------------------------------
// 窗口形态与屏幕
// ---------------------------------------------------------------------------

double PetBridge::WindowScale() const {
  const HMONITOR monitor =
      MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  return FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
}

std::vector<PetBridge::MonitorInfo> PetBridge::EnumMonitorsSorted() {
  std::vector<PetBridge::MonitorInfo> monitors;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                      reinterpret_cast<LPARAM>(&monitors));
  // 与 macOS NSScreen.screens 对齐：主屏排最前，下标即 moveToScreen 的 index。
  std::sort(monitors.begin(), monitors.end(),
            [](const MonitorInfo& a, const MonitorInfo& b) {
              return a.primary && !b.primary;
            });
  return monitors;
}

void PetBridge::ApplyActiveScreen() {
  const auto monitors = EnumMonitorsSorted();
  if (monitors.empty()) return;
  int index = active_screen_index_;
  index = std::clamp(index, 0, static_cast<int>(monitors.size()) - 1);
  active_screen_index_ = index;
  const RECT& work = monitors[index].work;
  SetWindowPos(window_, HWND_TOPMOST, work.left, work.top,
               work.right - work.left, work.bottom - work.top,
               SWP_NOACTIVATE);
}

void PetBridge::SetVisible(bool visible) {
  if (visible) {
    // 隐藏期间屏幕布局可能变化（外接屏热插拔），先重铺再显示。
    ApplyActiveScreen();
    ShowWindow(window_, SW_SHOWNOACTIVATE);
  } else {
    ShowWindow(window_, SW_HIDE);
  }
}

flutter::EncodableValue PetBridge::ScreenRects() {
  const auto monitors = EnumMonitorsSorted();
  RECT window_rect{};
  GetWindowRect(window_, &window_rect);
  const double scale = WindowScale();
  flutter::EncodableValue screens(std::vector<flutter::EncodableValue>());
  auto& items = std::get<std::vector<flutter::EncodableValue>>(screens);
  for (size_t index = 0; index < monitors.size(); ++index) {
    const RECT& work = monitors[index].work;
    flutter::EncodableMap item;
    item[flutter::EncodableValue("x")] = flutter::EncodableValue(
        (work.left - window_rect.left) / scale);
    item[flutter::EncodableValue("y")] = flutter::EncodableValue(
        (work.top - window_rect.top) / scale);
    item[flutter::EncodableValue("width")] =
        flutter::EncodableValue((work.right - work.left) / scale);
    item[flutter::EncodableValue("height")] =
        flutter::EncodableValue((work.bottom - work.top) / scale);
    item[flutter::EncodableValue("index")] =
        flutter::EncodableValue(static_cast<int32_t>(index));
    item[flutter::EncodableValue("primary")] =
        flutter::EncodableValue(monitors[index].primary);
    item[flutter::EncodableValue("active")] = flutter::EncodableValue(
        static_cast<int>(index) == active_screen_index_);
    items.emplace_back(std::move(item));
  }
  return screens;
}

flutter::EncodableMap PetBridge::WindowDiagnostics() {
  RECT frame{};
  GetWindowRect(window_, &frame);
  flutter::EncodableValue screens(std::vector<flutter::EncodableValue>());
  auto& items = std::get<std::vector<flutter::EncodableValue>>(screens);
  for (const auto& monitor : EnumMonitorsSorted()) {
    flutter::EncodableMap item;
    item[flutter::EncodableValue("x")] =
        flutter::EncodableValue(static_cast<double>(monitor.work.left));
    item[flutter::EncodableValue("y")] =
        flutter::EncodableValue(static_cast<double>(monitor.work.top));
    item[flutter::EncodableValue("width")] = flutter::EncodableValue(
        static_cast<double>(monitor.work.right - monitor.work.left));
    item[flutter::EncodableValue("height")] = flutter::EncodableValue(
        static_cast<double>(monitor.work.bottom - monitor.work.top));
    item[flutter::EncodableValue("isMain")] =
        flutter::EncodableValue(monitor.primary);
    items.emplace_back(std::move(item));
  }
  flutter::EncodableMap active_screen;
  const auto monitors = EnumMonitorsSorted();
  if (!monitors.empty()) {
    const int index = std::clamp(
        active_screen_index_, 0, static_cast<int>(monitors.size()) - 1);
    active_screen_index_ = index;
    const RECT& work = monitors[index].work;
    active_screen = flutter::EncodableMap{
        {flutter::EncodableValue("x"),
         flutter::EncodableValue(static_cast<double>(work.left))},
        {flutter::EncodableValue("y"),
         flutter::EncodableValue(static_cast<double>(work.top))},
        {flutter::EncodableValue("width"),
         flutter::EncodableValue(static_cast<double>(work.right - work.left))},
        {flutter::EncodableValue("height"),
         flutter::EncodableValue(static_cast<double>(work.bottom - work.top))}};
  }
  flutter::EncodableMap state{
      {flutter::EncodableValue("visible"),
       flutter::EncodableValue(IsWindowVisible(window_) != FALSE)},
      {flutter::EncodableValue("frame"),
       flutter::EncodableMap{
           {flutter::EncodableValue("x"),
            flutter::EncodableValue(static_cast<double>(frame.left))},
           {flutter::EncodableValue("y"),
            flutter::EncodableValue(static_cast<double>(frame.top))},
           {flutter::EncodableValue("width"),
            flutter::EncodableValue(static_cast<double>(frame.right - frame.left))},
           {flutter::EncodableValue("height"),
            flutter::EncodableValue(static_cast<double>(frame.bottom - frame.top))}}},
      {flutter::EncodableValue("screens"), std::move(screens)},
      {flutter::EncodableValue("activeScreenIndex"),
       flutter::EncodableValue(active_screen_index_)},
      {flutter::EncodableValue("activeScreen"), active_screen},
      // 兼容旧诊断脚本：union 现在就是活动屏。
      {flutter::EncodableValue("union"), active_screen}};
  return state;
}

void PetBridge::OnDisplayChanged() {
  const auto monitors = EnumMonitorsSorted();
  if (monitors.empty()) return;
  if (active_screen_index_ >= static_cast<int>(monitors.size())) {
    // 拔掉活动屏后下标越界：退回主屏。
    active_screen_index_ = 0;
  }
  ApplyActiveScreen();
  if (window_channel_) {
    window_channel_->InvokeMethod("screensChanged", nullptr);
  }
}

// ---------------------------------------------------------------------------
// 方法通道
// ---------------------------------------------------------------------------

void PetBridge::InstallMethodChannels() {
  const auto messenger = controller_->engine()->messenger();

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "dsh_pet/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* arguments = call.arguments();
        const auto* bool_arg = std::get_if<bool>(arguments);
        if (call.method_name() == "setInteractive") {
          // 穿透 = WS_EX_TRANSPARENT：置顶分层窗口加减该样式即可整体切换。
          LONG_PTR ex_style = GetWindowLongPtr(window_, GWL_EXSTYLE);
          const bool interactive = bool_arg != nullptr && *bool_arg;
          if (interactive) {
            ex_style &= ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
          } else {
            ex_style |= WS_EX_TRANSPARENT;
          }
          SetWindowLongPtr(window_, GWL_EXSTYLE, ex_style);
          result->Success();
        } else if (call.method_name() == "setFocusable") {
          // 面板要打字时去掉 WS_EX_NOACTIVATE 并把窗口带回前台；
          // 穿透状态只由 Dart 的命中判定决定，这里不再碰 WS_EX_TRANSPARENT。
          const bool focusable = bool_arg != nullptr && *bool_arg;
          focusable_ = focusable;
          LONG_PTR ex_style = GetWindowLongPtr(window_, GWL_EXSTYLE);
          if (focusable) {
            ex_style &= ~static_cast<LONG_PTR>(WS_EX_NOACTIVATE);
            SetWindowLongPtr(window_, GWL_EXSTYLE, ex_style);
            ForceSetForeground(window_);
          } else {
            ex_style |= WS_EX_NOACTIVATE;
            SetWindowLongPtr(window_, GWL_EXSTYLE, ex_style);
          }
          result->Success();
        } else if (call.method_name() == "setAlwaysOnTop") {
          const bool on_top = bool_arg == nullptr || *bool_arg;
          SetWindowPos(window_, on_top ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0,
                       0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
          result->Success();
        } else if (call.method_name() == "showWindow") {
          SetVisible(true);
          result->Success(flutter::EncodableValue(
              IsWindowVisible(window_) != FALSE));
        } else if (call.method_name() == "hideWindow") {
          SetVisible(false);
          result->Success(flutter::EncodableValue(
              IsWindowVisible(window_) != FALSE));
        } else if (call.method_name() == "isVisible") {
          result->Success(flutter::EncodableValue(
              IsWindowVisible(window_) != FALSE));
        } else if (call.method_name() == "windowState") {
          result->Success(flutter::EncodableValue(WindowDiagnostics()));
        } else if (call.method_name() == "getScreens") {
          // 返回结构对齐 macOS：顶层就是屏幕数组，Dart 侧按 List 解析。
          result->Success(ScreenRects());
        } else if (call.method_name() == "moveToScreen") {
          const auto* map = std::get_if<flutter::EncodableMap>(arguments);
          if (map == nullptr) {
            result->Error("window.bad-index", "缺少 screen index");
            return;
          }
          const auto index_it =
              map->find(flutter::EncodableValue("index"));
          const auto* index_value =
              index_it == map->end()
                  ? nullptr
                  : std::get_if<int32_t>(&index_it->second);
          const auto monitors = EnumMonitorsSorted();
          if (index_value == nullptr || *index_value < 0 ||
              *index_value >= static_cast<int32_t>(monitors.size())) {
            result->Error("window.bad-index", "屏幕下标非法");
            return;
          }
          active_screen_index_ = *index_value;
          const RECT& work = monitors[*index_value].work;
          SetWindowPos(window_, HWND_TOPMOST, work.left, work.top,
                       work.right - work.left, work.bottom - work.top,
                       SWP_NOACTIVATE);
          if (window_channel_) {
            window_channel_->InvokeMethod("screensChanged", nullptr);
          }
          POINT cursor{};
          GetCursorPos(&cursor);
          const double scale = WindowScale();
          flutter::EncodableMap reply{
              {flutter::EncodableValue("index"),
               flutter::EncodableValue(*index_value)},
              {flutter::EncodableValue("width"),
               flutter::EncodableValue(
                   (work.right - work.left) / scale)},
              {flutter::EncodableValue("height"),
               flutter::EncodableValue(
                   (work.bottom - work.top) / scale)},
              {flutter::EncodableValue("pointer"),
               flutter::EncodableMap{
                   {flutter::EncodableValue("x"),
                    flutter::EncodableValue((cursor.x - work.left) / scale)},
                   {flutter::EncodableValue("y"),
                    flutter::EncodableValue((cursor.y - work.top) / scale)}}}};
          result->Success(flutter::EncodableValue(std::move(reply)));
        } else if (call.method_name() == "quit") {
          if (tray_added_) {
            Shell_NotifyIconW(NIM_DELETE, &tray_);
            tray_added_ = false;
          }
          PostMessage(window_, WM_CLOSE, 0, 0);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  content_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "dsh_pet/content",
          &flutter::StandardMethodCodec::GetInstance());
  content_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "readFocusedText") {
          const flutter::EncodableMap content = ReadFocusedWindow();
          const auto error_it = content.find(flutter::EncodableValue("error"));
          if (error_it != content.end()) {
            // 对齐 macOS：读取失败抛结构化错误，Dart 侧按 PlatformException 降级。
            const auto* code = std::get_if<std::string>(&error_it->second);
            const auto* message =
                std::get_if<std::string>(&content.at(flutter::EncodableValue("message")));
            result->Error(code != nullptr ? code->c_str() : "ax.failed",
                          message != nullptr ? message->c_str() : "");
            return;
          }
          result->Success(flutter::EncodableValue(content));
        } else if (call.method_name() == "isTrusted") {
          // Windows 读取 UIA 不需要类似 macOS 的辅助功能授权。
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "requestTrust") {
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "notify") {
          const auto* map =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (map == nullptr || !tray_added_) {
            result->Error("notify.failed", "托盘未就绪或缺少通知内容");
            return;
          }
          std::wstring title = L"桌宠";
          std::wstring body = L"有新的消息";
          const auto title_it = map->find(flutter::EncodableValue("title"));
          if (title_it != map->end()) {
            if (const auto* text = std::get_if<std::string>(&title_it->second)) {
              if (!text->empty()) title = Utf8ToWide(*text);
            }
          }
          const auto body_it = map->find(flutter::EncodableValue("body"));
          if (body_it != map->end()) {
            if (const auto* text = std::get_if<std::string>(&body_it->second)) {
              if (!text->empty()) body = Utf8ToWide(*text);
            }
          }
          // 托盘气泡是 Windows 侧最轻量的系统通知，不需要额外的通知插件。
          tray_.uFlags = NIF_INFO;
          tray_.dwInfoFlags = NIIF_INFO;
          wcsncpy_s(tray_.szInfoTitle, title.c_str(), _TRUNCATE);
          wcsncpy_s(tray_.szInfo, body.c_str(), _TRUNCATE);
          if (!Shell_NotifyIconW(NIM_MODIFY, &tray_)) {
            result->Error("notify.failed", "托盘气泡发送失败");
            return;
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  input_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "dsh_pet/input",
          &flutter::StandardMethodCodec::GetInstance());
  input_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "activateApp") {
          const auto* map =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (map == nullptr) {
            result->Error("input.bad-args", "缺少 bundleId");
            return;
          }
          const auto bundle_it = map->find(flutter::EncodableValue("bundleId"));
          if (bundle_it == map->end()) {
            result->Error("input.bad-args", "缺少 bundleId");
            return;
          }
          const auto* bundle =
              std::get_if<std::string>(&bundle_it->second);
          if (bundle == nullptr || bundle->empty()) {
            result->Error("input.bad-args", "缺少 bundleId");
            return;
          }
          result->Success(flutter::EncodableValue(ActivateApp(*bundle)));
        } else if (call.method_name() == "pasteAndSubmit") {
          result->Success(flutter::EncodableValue(PasteAndSubmit()));
        } else if (call.method_name() == "openUrl") {
          const auto* map =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (map == nullptr) {
            result->Error("input.bad-url", "URL 非法");
            return;
          }
          const auto url_it = map->find(flutter::EncodableValue("url"));
          if (url_it == map->end()) {
            result->Error("input.bad-url", "URL 非法");
            return;
          }
          const auto* url = std::get_if<std::string>(&url_it->second);
          if (url == nullptr || url->empty()) {
            result->Error("input.bad-url", "URL 非法");
            return;
          }
          const HINSTANCE status = ShellExecuteW(
              nullptr, L"open", Utf8ToWide(*url).c_str(), nullptr, nullptr,
              SW_SHOWNORMAL);
          // ShellExecute 返回值 > 32 表示成功。
          result->Success(flutter::EncodableValue(
              reinterpret_cast<INT_PTR>(status) > 32));
        } else {
          result->NotImplemented();
        }
      });

  // 只发不收：托盘菜单动作 -> Dart。macOS 同名通道同款约定。
  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "dsh_pet/tray",
          &flutter::StandardMethodCodec::GetInstance());
}

// ---------------------------------------------------------------------------
// 事件通道
// ---------------------------------------------------------------------------

void PetBridge::InstallEventChannels() {
  const auto messenger = controller_->engine()->messenger();

  cursor_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, "dsh_pet/cursor",
          &flutter::StandardMethodCodec::GetInstance());
  cursor_event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
                    && events)
              -> std::unique_ptr<flutter::StreamHandlerError<
                  flutter::EncodableValue>> {
            cursor_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<
                  flutter::EncodableValue>> {
            cursor_sink_ = nullptr;
            return nullptr;
          }));

  app_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, "dsh_pet/app",
          &flutter::StandardMethodCodec::GetInstance());
  app_event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
                     && events)
              -> std::unique_ptr<flutter::StreamHandlerError<
                  flutter::EncodableValue>> {
            app_sink_ = std::move(events);
            // 先补当前前台，Dart 不用等下一次切换才有状态。
            const HWND foreground = GetForegroundWindow();
            if (foreground != nullptr) {
              PushAppEvent(foreground);
            }
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<
                  flutter::EncodableValue>> {
            app_sink_ = nullptr;
            return nullptr;
          }));
}

void PetBridge::PushAppEvent(HWND hwnd) {
  if (app_sink_ == nullptr || hwnd == nullptr) return;
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0) return;
  const std::wstring exe = ExeNameForPid(pid);
  if (exe.empty()) return;
  // Windows 没有 bundleId：约定用 exe 名（如 Trae.exe）当标识。
  flutter::EncodableMap event{
      {flutter::EncodableValue("bundleId"), flutter::EncodableValue(WideToUtf8(exe))},
      {flutter::EncodableValue("name"), flutter::EncodableValue(WideToUtf8(FileNameOf(exe)))},
      {flutter::EncodableValue("pid"), flutter::EncodableValue(static_cast<int32_t>(pid))}};
  app_sink_->AddEvent(flutter::EncodableValue(std::move(event)));
}

// ---------------------------------------------------------------------------
// 定时器
// ---------------------------------------------------------------------------

bool PetBridge::HandleTimer(UINT_PTR const timer_id) {
  if (timer_id == kCursorTimerId) {
    if (cursor_sink_ == nullptr) return true;
    POINT cursor{};
    if (!GetCursorPos(&cursor)) return true;
    RECT window_rect{};
    GetWindowRect(window_, &window_rect);
    const double scale = WindowScale();
    const double x = (cursor.x - window_rect.left) / scale;
    const double y = (cursor.y - window_rect.top) / scale;
    const bool down = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
    if (std::abs(x - last_cursor_x_) < 1 && std::abs(y - last_cursor_y_) < 1 &&
        down == last_mouse_down_) {
      return true;
    }
    last_cursor_x_ = x;
    last_cursor_y_ = y;
    last_mouse_down_ = down;
    flutter::EncodableMap event{
        {flutter::EncodableValue("x"), flutter::EncodableValue(x)},
        {flutter::EncodableValue("y"), flutter::EncodableValue(y)},
        {flutter::EncodableValue("down"), flutter::EncodableValue(down)}};
    cursor_sink_->AddEvent(flutter::EncodableValue(std::move(event)));
    return true;
  }
  if (timer_id == kPasteEnterTimerId) {
    // 等目标应用消费完粘贴再回车，否则可能贴到上一帧的位置。
    KillTimer(window_, kPasteEnterTimerId);
    INPUT inputs[2]{};
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wVk = VK_RETURN;
    inputs[0].ki.dwFlags = 0;
    inputs[1].type = INPUT_KEYBOARD;
    inputs[1].ki.wVk = VK_RETURN;
    inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, inputs, sizeof(INPUT));
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// 内容读取（UIA）
// ---------------------------------------------------------------------------

flutter::EncodableMap PetBridge::ReadFocusedWindow() {
  flutter::EncodableMap failure;
  const auto fail = [&failure](const char* code, const char* message) {
    failure[flutter::EncodableValue("error")] = flutter::EncodableValue(code);
    failure[flutter::EncodableValue("message")] =
        flutter::EncodableValue(message);
    return failure;
  };

  const HWND foreground = GetForegroundWindow();
  if (foreground == nullptr) return fail("ax.no-front", "没有前台应用");
  DWORD pid = 0;
  GetWindowThreadProcessId(foreground, &pid);
  const std::wstring exe = pid != 0 ? ExeNameForPid(pid) : L"";

  wchar_t title_buffer[256] = L"";
  GetWindowTextW(foreground, title_buffer, 256);

  IUIAutomation* automation = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_CUIAutomation, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation));
  if (FAILED(hr) || automation == nullptr) {
    return fail("ax.unavailable", "UIAutomation 不可用");
  }

  std::wstring text;
  IUIAutomationElement* element = nullptr;
  hr = automation->GetFocusedElement(&element);
  if (SUCCEEDED(hr) && element != nullptr) {
    // 焦点元素的值（输入框正文）；选区优先，和 macOS 的 AX 读取顺序一致。
    VARIANT value;
    VariantInit(&value);
    if (SUCCEEDED(element->GetCurrentPropertyValue(UIA_ValuePropertyId,
                                                   &value)) &&
        value.vt == VT_BSTR && value.bstrVal != nullptr) {
      text = value.bstrVal;
    }
    VariantClear(&value);

    IUIAutomationTextPattern* text_pattern = nullptr;
    if (SUCCEEDED(element->GetCurrentPatternAs(
            UIA_TextPatternId, IID_PPV_ARGS(&text_pattern))) &&
        text_pattern != nullptr) {
      IUIAutomationTextRangeArray* selection = nullptr;
      if (SUCCEEDED(text_pattern->GetSelection(&selection)) &&
          selection != nullptr) {
        int count = 0;
        selection->get_Length(&count);
        if (count > 0) {
          IUIAutomationTextRange* range = nullptr;
          if (SUCCEEDED(selection->GetElement(0, &range)) && range != nullptr) {
            BSTR selected = nullptr;
            if (SUCCEEDED(range->GetText(-1, &selected)) && selected != nullptr) {
              if (wcslen(selected) > 0) text = selected;
              SysFreeString(selected);
            }
            range->Release();
          }
        }
        selection->Release();
      }
      text_pattern->Release();
    }
    element->Release();
  }
  automation->Release();

  return flutter::EncodableMap{
      {flutter::EncodableValue("bundleId"), flutter::EncodableValue(WideToUtf8(exe))},
      {flutter::EncodableValue("title"), flutter::EncodableValue(WideToUtf8(title_buffer))},
      {flutter::EncodableValue("text"), flutter::EncodableValue(WideToUtf8(text))}};
}

// ---------------------------------------------------------------------------
// 按键注入与应用激活
// ---------------------------------------------------------------------------

bool PetBridge::PasteAndSubmit() {
  INPUT inputs[4]{};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = VK_CONTROL;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = 'V';
  inputs[2].type = INPUT_KEYBOARD;
  inputs[2].ki.wVk = 'V';
  inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
  inputs[3].type = INPUT_KEYBOARD;
  inputs[3].ki.wVk = VK_CONTROL;
  inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
  if (SendInput(4, inputs, sizeof(INPUT)) != 4) return false;
  SetTimer(window_, kPasteEnterTimerId, kPasteEnterDelayMs, nullptr);
  return true;
}

bool PetBridge::ActivateApp(const std::string& exe_name) {
  // Windows 上 "bundleId" 约定为 exe 名；兼容用户填全路径，取文件名比较。
  FindWindowContext context{ToLowerWide(FileNameOf(Utf8ToWide(exe_name))),
                            nullptr};
  if (context.target_exe.empty()) return false;
  EnumWindows(FindWindowByExe, reinterpret_cast<LPARAM>(&context));
  if (context.found == nullptr) return false;
  ShowWindow(context.found, SW_RESTORE);
  ForceSetForeground(context.found);
  return true;
}

// ---------------------------------------------------------------------------
// 托盘
// ---------------------------------------------------------------------------

void PetBridge::InstallTray() {
  tray_ = {};
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = window_;
  tray_.uID = 1;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_.uCallbackMessage = kTrayCallbackMessage;
  tray_.hIcon =
      LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(tray_.szTip, L"桌宠");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_) == TRUE;
}

void PetBridge::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  const bool visible = IsWindowVisible(window_) != FALSE;
  AppendMenuW(menu, MF_STRING, static_cast<UINT_PTR>(kMenuToggle),
              visible ? L"隐藏宠物" : L"显示宠物");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, static_cast<UINT_PTR>(kMenuChat), L"打开对话框");
  AppendMenuW(menu, MF_STRING, static_cast<UINT_PTR>(kMenuSettings), L"打开设置");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, static_cast<UINT_PTR>(kMenuQuit), L"退出桌宠");
  POINT cursor{};
  GetCursorPos(&cursor);
  // Win32 经典坑：不先 SetForegroundWindow，菜单弹出后不会自动消失。
  SetForegroundWindow(window_);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, window_,
                 nullptr);
  DestroyMenu(menu);
}

bool PetBridge::HandleTrayMessage(UINT const message, WPARAM const wparam,
                                  LPARAM const lparam) {
  if (message == kTrayCallbackMessage) {
    if (lparam == WM_LBUTTONUP || lparam == WM_RBUTTONUP) {
      ShowTrayMenu();
      return true;
    }
    return false;
  }
  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kMenuToggle:
        SetVisible(!IsWindowVisible(window_));
        return true;
      case kMenuChat:
        tray_channel_->InvokeMethod(
            "openPanel",
            std::make_unique<flutter::EncodableValue>(std::string("chat")));
        return true;
      case kMenuSettings:
        tray_channel_->InvokeMethod(
            "openPanel",
            std::make_unique<flutter::EncodableValue>(std::string("settings")));
        return true;
      case kMenuQuit:
        if (tray_added_) {
          Shell_NotifyIconW(NIM_DELETE, &tray_);
          tray_added_ = false;
        }
        PostMessage(window_, WM_CLOSE, 0, 0);
        return true;
      default:
        return false;
    }
  }
  return false;
}
