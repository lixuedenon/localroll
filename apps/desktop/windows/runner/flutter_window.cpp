#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

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

  // Global keys: register(id, modifiers, key) / unregister(id).
  hotkeys_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "keepnear/hotkeys",
      &flutter::StandardMethodCodec::GetInstance());
  hotkeys_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* args = std::get_if<flutter::EncodableList>(call.arguments());
        auto num = [args](size_t i) -> int {
          if (!args || args->size() <= i) return 0;
          if (const auto* v = std::get_if<int32_t>(&(*args)[i])) return *v;
          if (const auto* w = std::get_if<int64_t>(&(*args)[i])) return static_cast<int>(*w);
          return 0;
        };
        if (call.method_name() == "register") {
          const int id = num(0);
          UnregisterHotKey(GetHandle(), id);
          const BOOL ok = RegisterHotKey(GetHandle(), id,
                                         static_cast<UINT>(num(1)) | MOD_NOREPEAT,
                                         static_cast<UINT>(num(2)));
          result->Success(flutter::EncodableValue(ok != FALSE));
        } else if (call.method_name() == "unregister") {
          UnregisterHotKey(GetHandle(), num(0));
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  hotkeys_ = nullptr;
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

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_HOTKEY:
      if (hotkeys_) {
        hotkeys_->InvokeMethod("pressed", std::make_unique<flutter::EncodableValue>(static_cast<int32_t>(wparam)));
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
