// apps/desktop/windows/pick/pick.cpp
//
// LocalRoll's "point at what to record": the part of the screen under the
// mouse (a button, a panel, a whole window, found with Windows UI
// Automation) is outlined; a click takes it. The wheel goes to the part
// around it (up) or back (down). Esc: drag a box instead. Right click:
// give up. Nothing is clicked in the apps meanwhile.
//
//   lr_pick.exe "<tip shown at the top>"
// Prints:  ready
//          rect <x> <y> <w> <h>   (screen pixels) when one was clicked
//          back                   Esc
//          cancel                 right click / stdin closed

#ifndef UNICODE
#define UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <uiautomation.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr UINT WM_WHEEL = WM_APP + 1;
constexpr UINT WM_DONE = WM_APP + 2;
constexpr UINT_PTR kTimer = 1;

IUIAutomation* g_uia = nullptr;
IUIAutomationTreeWalker* g_walker = nullptr;
HWND g_frame = nullptr, g_tip = nullptr;
HHOOK g_mouse = nullptr, g_keys = nullptr;
POINT g_at{-1, -1}, g_asked{-99999, -99999};
DWORD g_self = 0;
std::wstring g_tipText;
bool g_finished = false;

// The part under the mouse, then the parts around it.
std::vector<IUIAutomationElement*> g_chain;
size_t g_level = 0;
RECT g_shown{0, 0, 0, 0};

void say(const char* s) {
  std::fputs(s, stdout);
  std::fputc('\n', stdout);
  std::fflush(stdout);
}

void clearChain() {
  for (auto* e : g_chain) e->Release();
  g_chain.clear();
  g_level = 0;
}

bool rectOf(IUIAutomationElement* e, RECT& r) {
  if (!e || FAILED(e->get_CurrentBoundingRectangle(&r))) return false;
  return r.right - r.left >= 8 && r.bottom - r.top >= 8;
}

bool isDesktop(IUIAutomationElement* e) {
  IUIAutomationElement* root = nullptr;
  if (FAILED(g_uia->GetRootElement(&root)) || !root) return false;
  BOOL same = FALSE;
  g_uia->CompareElements(e, root, &same);
  root->Release();
  return same == TRUE;
}

// A bitmap with premultiplied alpha onto a layered window.
void put(HWND w, int x, int y, int cw, int ch, const std::vector<uint32_t>& px) {
  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth = cw;
  bi.bmiHeader.biHeight = -ch;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  void* bits = nullptr;
  HBITMAP bmp = CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bmp && bits) {
    std::copy(px.begin(), px.end(), static_cast<uint32_t*>(bits));
    HGDIOBJ old = SelectObject(mem, bmp);
    POINT dst{x, y}, zero{0, 0};
    SIZE sz{cw, ch};
    BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(w, screen, &dst, &sz, mem, &zero, 0, &bf, ULW_ALPHA);
    SelectObject(mem, old);
  }
  if (bmp) DeleteObject(bmp);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
}

// The monitor's scale (shcore, loaded when there; else 96).
void GetDpiForMonitorSafe(HMONITOR mon, UINT& x, UINT& y) {
  using Fn = HRESULT(WINAPI*)(HMONITOR, int, UINT*, UINT*);
  static Fn fn = []() -> Fn {
    HMODULE m = LoadLibraryW(L"shcore.dll");
    return m ? reinterpret_cast<Fn>(reinterpret_cast<void*>(GetProcAddress(m, "GetDpiForMonitor"))) : nullptr;
  }();
  if (!fn || FAILED(fn(mon, 0, &x, &y))) x = y = 96;
}

uint32_t pre(uint8_t a, uint8_t r, uint8_t g, uint8_t b) {
  return ((uint32_t)a << 24) | ((uint32_t)(r * a / 255) << 16) | ((uint32_t)(g * a / 255) << 8) | (uint32_t)(b * a / 255);
}

// The outline: a blue edge, lightly tinted inside.
void outline(const RECT& r) {
  if (EqualRect(&r, &g_shown)) return;
  g_shown = r;
  const int e = 3;
  const int x = r.left - e, y = r.top - e, w = r.right - r.left + 2 * e, h = r.bottom - r.top + 2 * e;
  if (w <= 0 || h <= 0 || w > 20000 || h > 20000) return;
  std::vector<uint32_t> px((size_t)w * h);
  const uint32_t edge = pre(255, 10, 132, 255), fill = pre(40, 10, 132, 255);
  for (int j = 0; j < h; j++) {
    for (int i = 0; i < w; i++) {
      const bool onEdge = i < e || j < e || i >= w - e || j >= h - e;
      px[(size_t)j * w + i] = onEdge ? edge : fill;
    }
  }
  put(g_frame, x, y, w, h, px);
  ShowWindow(g_frame, SW_SHOWNOACTIVATE);
}

void tip() {
  if (g_tipText.empty()) return;
  HMONITOR mon = MonitorFromPoint(g_at.x < 0 ? POINT{0, 0} : g_at, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO mi{sizeof(mi)};
  GetMonitorInfoW(mon, &mi);
  UINT dpix = 96, dpiy = 96;
  GetDpiForMonitorSafe(mon, dpix, dpiy);
  const UINT dpi = dpix;
  const int fs = MulDiv(16, (int)dpi, 96);
  HFONT font = CreateFontW(-fs, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  HGDIOBJ of = SelectObject(mem, font);
  RECT m{0, 0, 0, 0};
  DrawTextW(mem, g_tipText.c_str(), -1, &m, DT_CALCRECT | DT_SINGLELINE);
  const int pad = MulDiv(14, (int)dpi, 96);
  const int w = m.right + 2 * pad, h = m.bottom + pad;
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  void* bits = nullptr;
  HBITMAP bmp = CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bmp && bits) {
    HGDIOBJ ob = SelectObject(mem, bmp);
    auto* p = static_cast<uint32_t*>(bits);
    for (int i = 0; i < w * h; i++) p[i] = 0x00202020;
    SetBkMode(mem, TRANSPARENT);
    SetTextColor(mem, RGB(255, 255, 255));
    RECT tr{pad, pad / 2, w - pad, h - pad / 2};
    DrawTextW(mem, g_tipText.c_str(), -1, &tr, DT_SINGLELINE | DT_CENTER | DT_VCENTER);
    GdiFlush();
    // GDI leaves alpha at 0: the whole box at 230, text included.
    std::vector<uint32_t> px((size_t)w * h);
    for (int i = 0; i < w * h; i++) {
      const uint32_t c = p[i];
      px[i] = pre(230, (c >> 16) & 255, (c >> 8) & 255, c & 255);
    }
    SelectObject(mem, ob);
    const int x = (mi.rcMonitor.left + mi.rcMonitor.right) / 2 - w / 2, y = mi.rcMonitor.top + MulDiv(24, (int)dpi, 96);
    put(g_tip, x, y, w, h, px);
    ShowWindow(g_tip, SW_SHOWNOACTIVATE);
  }
  if (bmp) DeleteObject(bmp);
  SelectObject(mem, of);
  DeleteObject(font);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
}

// Asks what is under the mouse (on the timer, never in the hooks).
void look() {
  if (g_at.x == g_asked.x && g_at.y == g_asked.y) return;
  g_asked = g_at;
  IUIAutomationElement* e = nullptr;
  if (FAILED(g_uia->ElementFromPoint(g_at, &e)) || !e) return;
  int pid = 0;
  e->get_CurrentProcessId(&pid);
  if ((DWORD)pid == g_self) {
    e->Release();
    return;
  }
  // Same part as now: keep the level the wheel chose.
  if (!g_chain.empty()) {
    BOOL same = FALSE;
    g_uia->CompareElements(e, g_chain[0], &same);
    if (same) {
      e->Release();
      return;
    }
  }
  clearChain();
  g_chain.push_back(e);
  // Tiny parts: start from the first one around it that is big enough.
  RECT r;
  while (!rectOf(g_chain.back(), r)) {
    IUIAutomationElement* up = nullptr;
    if (FAILED(g_walker->GetParentElement(g_chain.back(), &up)) || !up || isDesktop(up)) {
      if (up) up->Release();
      break;
    }
    g_chain.push_back(up);
    g_level = g_chain.size() - 1;
  }
  if (rectOf(g_chain[g_level], r)) outline(r);
}

void wheel(int delta) {
  if (g_chain.empty()) return;
  RECT r;
  if (delta > 0) {
    // Up: the part around this one (a different size; not the desktop).
    RECT now{};
    rectOf(g_chain[g_level], now);
    size_t k = g_level;
    while (true) {
      if (k + 1 < g_chain.size()) {
        k++;
      } else {
        IUIAutomationElement* up = nullptr;
        if (FAILED(g_walker->GetParentElement(g_chain.back(), &up)) || !up) break;
        if (isDesktop(up)) {
          up->Release();
          break;
        }
        g_chain.push_back(up);
        k = g_chain.size() - 1;
      }
      if (rectOf(g_chain[k], r) && !EqualRect(&r, &now)) {
        g_level = k;
        break;
      }
    }
  } else {
    RECT now{};
    rectOf(g_chain[g_level], now);
    while (g_level > 0) {
      g_level--;
      if (rectOf(g_chain[g_level], r) && !EqualRect(&r, &now)) break;
    }
  }
  if (rectOf(g_chain[g_level], r)) outline(r);
}

void finish(const char* what) {
  if (g_finished) return;
  g_finished = true;
  say(what);
  PostQuitMessage(0);
}

LRESULT CALLBACK mouseHook(int code, WPARAM w, LPARAM l) {
  if (code == HC_ACTION) {
    const auto* m = reinterpret_cast<MSLLHOOKSTRUCT*>(l);
    switch (w) {
      case WM_MOUSEMOVE:
        g_at = m->pt;
        break;
      case WM_MOUSEWHEEL:
        PostMessageW(g_frame, WM_WHEEL, (WPARAM)(short)HIWORD(m->mouseData), 0);
        return 1;
      case WM_LBUTTONDOWN:
      case WM_RBUTTONDOWN:
      case WM_MBUTTONDOWN:
        return 1;
      case WM_LBUTTONUP:
        PostMessageW(g_frame, WM_DONE, 1, 0);
        return 1;
      case WM_RBUTTONUP:
        PostMessageW(g_frame, WM_DONE, 2, 0);
        return 1;
      case WM_MBUTTONUP:
        return 1;
      default:
        break;
    }
  }
  return CallNextHookEx(g_mouse, code, w, l);
}

LRESULT CALLBACK keyHook(int code, WPARAM w, LPARAM l) {
  if (code == HC_ACTION) {
    const auto* k = reinterpret_cast<KBDLLHOOKSTRUCT*>(l);
    if (k->vkCode == VK_ESCAPE) {
      if (w == WM_KEYUP || w == WM_SYSKEYUP) PostMessageW(g_frame, WM_DONE, 3, 0);
      return 1;
    }
  }
  return CallNextHookEx(g_keys, code, w, l);
}

LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) {
  switch (m) {
    case WM_TIMER:
      look();
      return 0;
    case WM_WHEEL:
      wheel((int)(short)w);
      return 0;
    case WM_DONE:
      if (w == 1) {
        RECT r;
        look();
        if (!g_chain.empty() && rectOf(g_chain[g_level], r)) {
          char buf[96];
          std::snprintf(buf, sizeof(buf), "rect %ld %ld %ld %ld", r.left, r.top, r.right - r.left, r.bottom - r.top);
          finish(buf);
        }
      } else {
        finish(w == 3 ? "back" : "cancel");
      }
      return 0;
    default:
      return DefWindowProcW(h, m, w, l);
  }
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  g_self = GetCurrentProcessId();
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv && argc > 1) g_tipText = argv[1];
  if (argv) LocalFree(argv);
  if (FAILED(CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&g_uia))) || !g_uia ||
      FAILED(g_uia->get_ControlViewWalker(&g_walker)) || !g_walker) {
    say("error uia");
    return 1;
  }
  WNDCLASSW wc{};
  wc.lpfnWndProc = proc;
  wc.hInstance = inst;
  wc.lpszClassName = L"LocalRollPick";
  RegisterClassW(&wc);
  const DWORD ex = WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
  g_frame = CreateWindowExW(ex, wc.lpszClassName, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, inst, nullptr);
  g_tip = CreateWindowExW(ex, wc.lpszClassName, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, inst, nullptr);
  if (!g_frame || !g_tip) {
    say("error window");
    return 1;
  }
  g_mouse = SetWindowsHookExW(WH_MOUSE_LL, mouseHook, inst, 0);
  g_keys = SetWindowsHookExW(WH_KEYBOARD_LL, keyHook, inst, 0);
  if (!g_mouse || !g_keys) {
    say("error hook");
    return 1;
  }
  GetCursorPos(&g_at);
  tip();
  SetTimer(g_frame, kTimer, 60, nullptr);
  HWND frame = g_frame;
  std::thread([frame]() {
    std::string line;
    while (std::getline(std::cin, line)) {
      if (line.rfind("quit", 0) == 0) break;
    }
    PostMessageW(frame, WM_DONE, 2, 0);
  }).detach();
  say("ready");
  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  UnhookWindowsHookEx(g_mouse);
  UnhookWindowsHookEx(g_keys);
  clearChain();
  g_walker->Release();
  g_uia->Release();
  CoUninitialize();
  // Not waiting for stdin's reader.
  ExitProcess(0);
}
