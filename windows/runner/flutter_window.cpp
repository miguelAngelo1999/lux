#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

UINT GetShowWindowMessage() {
  static const UINT kShowWindowMsg =
      ::RegisterWindowMessageW(L"com.github.igoogolx.lux.SHOW_WINDOW");
  return kShowWindowMsg;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Allow non-elevated launches to send kShowWindowMsg to an elevated window.
  ::ChangeWindowMessageFilterEx(GetHandle(), GetShowWindowMessage(),
                                MSGFLT_ALLOW, nullptr);

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

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
      //delete this->Show()
  });

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == GetShowWindowMessage()) {
    LONG_PTR ex_style = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if ((ex_style & WS_EX_TOOLWINDOW) != 0) {
      ::SetWindowLongPtrW(
          hwnd, GWL_EXSTYLE,
          (ex_style & ~static_cast<LONG_PTR>(WS_EX_TOOLWINDOW)) |
              WS_EX_APPWINDOW);
    }
    ::ShowWindow(hwnd, SW_SHOW);
    ::ShowWindow(hwnd, SW_RESTORE);
    ::SetForegroundWindow(hwnd);
    ::BringWindowToTop(hwnd);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
