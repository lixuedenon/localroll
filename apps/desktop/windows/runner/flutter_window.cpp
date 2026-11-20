#include "flutter_window.h"

#include <optional>
#include <string>
#include <vector>

#include <commctrl.h>
#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// The Flutter view's window, subclassed: its WM_DROPFILES comes here.
LRESULT CALLBACK DropSubclass(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam, UINT_PTR, DWORD_PTR data) {
  if (msg == WM_DROPFILES) {
    reinterpret_cast<FlutterWindow*>(data)->OnFilesDropped(reinterpret_cast<HDROP>(wparam));
    return 0;
  }
  return DefSubclassProc(hwnd, msg, wparam, lparam);
}

std::wstring Wide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), out.data(), n);
  return out;
}

// Opens the folder of paths[0] with every path in it chosen.
bool Reveal(const std::vector<std::wstring>& paths) {
  if (paths.empty()) return false;
  const std::wstring& first = paths.front();
  const size_t cut = first.find_last_of(L"\\/");
  if (cut == std::wstring::npos) return false;
  const std::wstring dir = first.substr(0, cut);
  PIDLIST_ABSOLUTE folder = ILCreateFromPathW(dir.c_str());
  if (!folder) return false;
  std::vector<PIDLIST_ABSOLUTE> items;
  for (const auto& p : paths) {
    if (PIDLIST_ABSOLUTE item = ILCreateFromPathW(p.c_str())) items.push_back(item);
  }
  bool ok = false;
  if (!items.empty()) {
    std::vector<PCUITEMID_CHILD> kids;
    for (auto item : items) kids.push_back(ILFindLastID(item));
    ok = SUCCEEDED(SHOpenFolderAndSelectItems(folder, static_cast<UINT>(kids.size()), kids.data(), 0));
  }
  for (auto item : items) ILFree(item);
  ILFree(folder);
  return ok;
}

// The clipboard: files (pasted into a folder as copies) and, for one
// photo, the picture too (pasted into a chat, Word, Paint…). [bgra]: top
// row first, 4 bytes a pixel.
bool CopyToClipboard(HWND hwnd, const std::vector<std::wstring>& files, const std::vector<uint8_t>* bgra, int w, int h) {
  if (!OpenClipboard(hwnd)) return false;
  EmptyClipboard();
  bool ok = false;
  if (!files.empty()) {
    size_t chars = 1;
    for (const auto& f : files) chars += f.size() + 1;
    HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DROPFILES) + chars * sizeof(wchar_t));
    if (g) {
      auto* df = static_cast<DROPFILES*>(GlobalLock(g));
      df->pFiles = sizeof(DROPFILES);
      df->fWide = TRUE;
      auto* p = reinterpret_cast<wchar_t*>(reinterpret_cast<BYTE*>(df) + sizeof(DROPFILES));
      for (const auto& f : files) {
        memcpy(p, f.c_str(), f.size() * sizeof(wchar_t));
        p += f.size();
        *p++ = 0;
      }
      *p = 0;
      GlobalUnlock(g);
      if (SetClipboardData(CF_HDROP, g)) {
        ok = true;
      } else {
        GlobalFree(g);
      }
    }
    // A copy, not a move, when pasted into a folder.
    const UINT effect = RegisterClipboardFormatW(L"Preferred DropEffect");
    if (HGLOBAL e = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD))) {
      *static_cast<DWORD*>(GlobalLock(e)) = DROPEFFECT_COPY;
      GlobalUnlock(e);
      if (!SetClipboardData(effect, e)) GlobalFree(e);
    }
  }
  if (bgra && w > 0 && h > 0 && bgra->size() >= static_cast<size_t>(w) * h * 4) {
    const size_t row = static_cast<size_t>(w) * 4;
    HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE, sizeof(BITMAPINFOHEADER) + row * h);
    if (g) {
      auto* bi = static_cast<BITMAPINFOHEADER*>(GlobalLock(g));
      ZeroMemory(bi, sizeof(BITMAPINFOHEADER));
      bi->biSize = sizeof(BITMAPINFOHEADER);
      bi->biWidth = w;
      bi->biHeight = h;  // bottom row first
      bi->biPlanes = 1;
      bi->biBitCount = 32;
      bi->biCompression = BI_RGB;
      bi->biSizeImage = static_cast<DWORD>(row * h);
      auto* dst = reinterpret_cast<BYTE*>(bi + 1);
      for (int y = 0; y < h; y++) memcpy(dst + (h - 1 - y) * row, bgra->data() + y * row, row);
      GlobalUnlock(g);
      if (SetClipboardData(CF_DIB, g)) {
        ok = true;
      } else {
        GlobalFree(g);
      }
    }
  }
  CloseClipboard();
  return ok;
}

std::string Utf8(const std::wstring& w) {
  if (w.empty()) return std::string();
  const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  std::string out(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), out.data(), n, nullptr, nullptr);
  return out;
}

}  // namespace

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
  // Show in folder: reveal([path, …]) → true when the files were chosen.
  shell_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "keepnear/shell",
      &flutter::StandardMethodCodec::GetInstance());
  shell_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "copy") {
          // copy({files: [...], bgra: bytes?, w, h})
          std::vector<std::wstring> files;
          const std::vector<uint8_t>* bgra = nullptr;
          int w = 0, h = 0;
          if (const auto* m = std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto at = [m](const char* k) -> const flutter::EncodableValue* {
              auto it = m->find(flutter::EncodableValue(std::string(k)));
              return it == m->end() ? nullptr : &it->second;
            };
            if (const auto* v = at("files")) {
              if (const auto* l = std::get_if<flutter::EncodableList>(v)) {
                for (const auto& f : *l) {
                  if (const auto* str = std::get_if<std::string>(&f)) files.push_back(Wide(*str));
                }
              }
            }
            if (const auto* v = at("bgra")) bgra = std::get_if<std::vector<uint8_t>>(v);
            if (const auto* v = at("w")) {
              if (const auto* i = std::get_if<int32_t>(v)) w = *i;
            }
            if (const auto* v = at("h")) {
              if (const auto* i = std::get_if<int32_t>(v)) h = *i;
            }
          }
          result->Success(flutter::EncodableValue(CopyToClipboard(GetHandle(), files, bgra, w, h)));
          return;
        }
        if (call.method_name() != "reveal") {
          result->NotImplemented();
          return;
        }
        std::vector<std::wstring> paths;
        if (const auto* args = std::get_if<flutter::EncodableList>(call.arguments())) {
          for (const auto& v : *args) {
            if (const auto* s = std::get_if<std::string>(&v)) paths.push_back(Wide(*s));
          }
        }
        result->Success(flutter::EncodableValue(Reveal(paths)));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  AllowDropWhenElevated();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::AllowDropWhenElevated() {
  if (!IsUserAnAdmin()) return;
  const HWND view = flutter_controller_->view()->GetNativeWindow();
  // desktop_drop's OLE target can never get anything here; without it,
  // Windows falls back to WM_DROPFILES.
  RevokeDragDrop(view);
  for (const HWND w : {view, GetHandle()}) {
    ChangeWindowMessageFilterEx(w, WM_DROPFILES, MSGFLT_ALLOW, nullptr);
    ChangeWindowMessageFilterEx(w, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
    ChangeWindowMessageFilterEx(w, 0x0049 /* WM_COPYGLOBALDATA */, MSGFLT_ALLOW, nullptr);
  }
  DragAcceptFiles(view, TRUE);
  SetWindowSubclass(view, DropSubclass, 1, reinterpret_cast<DWORD_PTR>(this));
  admin_drop_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "desktop_drop",
      &flutter::StandardMethodCodec::GetInstance());
}

void FlutterWindow::OnFilesDropped(HDROP drop) {
  POINT pt{};
  DragQueryPoint(drop, &pt);  // the view's own coordinates, as desktop_drop
  flutter::EncodableList files;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; ++i) {
    const UINT len = DragQueryFileW(drop, i, nullptr, 0);
    std::wstring name(len, L'\0');
    DragQueryFileW(drop, i, name.data(), len + 1);
    files.push_back(flutter::EncodableValue(Utf8(name)));
  }
  DragFinish(drop);
  if (!admin_drop_ || files.empty()) return;
  admin_drop_->InvokeMethod("entered", std::make_unique<flutter::EncodableValue>(flutter::EncodableList{
                                           flutter::EncodableValue(double(pt.x)), flutter::EncodableValue(double(pt.y))}));
  admin_drop_->InvokeMethod("performOperation", std::make_unique<flutter::EncodableValue>(files));
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_ && admin_drop_) {
    RemoveWindowSubclass(flutter_controller_->view()->GetNativeWindow(), DropSubclass, 1);
  }
  admin_drop_ = nullptr;
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
