#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 桌宠原生桥：透明置顶、穿透、托盘、光标流等都在这里装配。
  // 必须在 view 存在后、首帧显示前安装。
  pet_bridge_ = std::make_unique<PetBridge>(GetHandle(), flutter_controller_.get());
  pet_bridge_->Install();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // SW_SHOWNOACTIVATE：桌宠出生不抢用户正在用的窗口焦点。
    ShowWindow(GetHandle(), SW_SHOWNOACTIVATE);
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  pet_bridge_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // 托盘回调 / 菜单命令：转发给原生桥，消费掉的消息不再进入默认处理。
  if (pet_bridge_ && pet_bridge_->HandleTrayMessage(message, wparam, lparam)) {
    return 0;
  }

  switch (message) {
    case WM_DISPLAYCHANGE:
      // 屏幕热插拔/分辨率变化：重铺活动屏并通知 Dart 重取屏幕列表。
      if (pet_bridge_) {
        pet_bridge_->OnDisplayChanged();
      }
      break;
    case WM_TIMER:
      if (pet_bridge_ && pet_bridge_->HandleTimer(static_cast<UINT_PTR>(wparam))) {
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
