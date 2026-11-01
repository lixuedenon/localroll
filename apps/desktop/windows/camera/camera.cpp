// apps/desktop/windows/camera/camera.cpp
//
// LocalRoll's camera bubble: the webcam (Media Foundation) in a small
// round / rounded-square window, always on top, with a thin white edge.
// Dragged anywhere with the mouse; a double-click switches round <-> square.
// It is a normal window, so a screen recording films it as it is. For an
// explanation it can also write what it shows (square, no mask) into a
// video: frames go to an ffmpeg LocalRoll gives (raw BGRA on its stdin).
//
// Commands (stdin, one per line, UTF-8):
//   list                      -> "camera <name>" lines, then "end"
//   open <name>               -> "opened <w> <h> <name>" | "error nocamera" | "error open"
//   place <x> <y> <size>      screen pixels (top-left, side)
//   shape round|square        mirror 0|1        show        hide
//   record <fps> <side> <cmd> start ffmpeg <cmd> and feed it -> "recording" | "error record"
//   pause | resume            the recording's clock stops / goes on
//   stoprec                   -> "saved <frames>"
//   quit
// Prints "ready" at start, and "pos <x> <y> <size> <shape>" when the user
// moved it or changed its shape.

#ifndef UNICODE
#define UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr UINT WM_CMD = WM_APP + 1;
constexpr UINT_PTR kTimer = 1;

std::mutex g_out;

void say(const std::string& s) {
  std::lock_guard<std::mutex> l(g_out);
  std::fputs(s.c_str(), stdout);
  std::fputc('\n', stdout);
  std::fflush(stdout);
}

template <class T>
void release(T*& p) {
  if (p) {
    p->Release();
    p = nullptr;
  }
}

std::wstring wide(const std::string& s) {
  if (s.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
  return w;
}

std::string utf8(const wchar_t* w) {
  if (!w) return {};
  const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (n <= 1) return {};
  std::string s(n - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
  return s;
}

// ---- The camera ----------------------------------------------------------

struct Frame {
  int w = 0, h = 0;
  std::vector<uint8_t> bgra;  // top-down, w * 4 per row
  uint64_t n = 0;             // how many have come
};

std::mutex g_frameLock;
Frame g_frame;
std::atomic<bool> g_capturing{false};
std::thread g_capture;

std::vector<std::pair<std::string, IMFActivate*>> listCameras() {
  std::vector<std::pair<std::string, IMFActivate*>> out;
  IMFAttributes* attr = nullptr;
  if (FAILED(MFCreateAttributes(&attr, 1))) return out;
  attr->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  IMFActivate** devs = nullptr;
  UINT32 n = 0;
  if (SUCCEEDED(MFEnumDeviceSources(attr, &devs, &n))) {
    for (UINT32 i = 0; i < n; i++) {
      wchar_t* name = nullptr;
      UINT32 len = 0;
      std::string s;
      if (SUCCEEDED(devs[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &len))) {
        s = utf8(name);
        CoTaskMemFree(name);
      }
      out.push_back({s, devs[i]});
    }
    CoTaskMemFree(devs);
  }
  attr->Release();
  return out;
}

void stopCamera() {
  g_capturing = false;
  if (g_capture.joinable()) g_capture.join();
}

// Opens [name] (empty: the first one); frames then come into g_frame.
bool openCamera(const std::string& name, std::string& used, int& outW, int& outH, bool& none) {
  stopCamera();
  none = false;
  auto cams = listCameras();
  if (cams.empty()) {
    none = true;
    return false;
  }
  size_t pick = 0;
  for (size_t i = 0; i < cams.size(); i++) {
    if (!name.empty() && cams[i].first == name) pick = i;
  }
  used = cams[pick].first;
  IMFMediaSource* src = nullptr;
  HRESULT hr = cams[pick].second->ActivateObject(IID_PPV_ARGS(&src));
  for (auto& c : cams) c.second->Release();
  if (FAILED(hr) || !src) return false;

  IMFAttributes* ra = nullptr;
  MFCreateAttributes(&ra, 2);
  ra->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  IMFSourceReader* reader = nullptr;
  hr = MFCreateSourceReaderFromMediaSource(src, ra, &reader);
  ra->Release();
  if (FAILED(hr) || !reader) {
    src->Shutdown();
    src->Release();
    return false;
  }
  // The camera's own format nearest 1280x720 (frame rate as high as it goes).
  IMFMediaType* best = nullptr;
  double bestScore = 1e18;
  for (DWORD i = 0;; i++) {
    IMFMediaType* t = nullptr;
    if (FAILED(reader->GetNativeMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &t))) break;
    UINT32 w = 0, h = 0, num = 0, den = 1;
    MFGetAttributeSize(t, MF_MT_FRAME_SIZE, &w, &h);
    MFGetAttributeRatio(t, MF_MT_FRAME_RATE, &num, &den);
    const double fps = den ? (double)num / den : 0;
    const double score = std::fabs((double)w * h - 1280.0 * 720.0) / 1000.0 + (fps < 24 ? 5000 : 0) - std::min(fps, 30.0);
    if (w >= 320 && score < bestScore) {
      bestScore = score;
      release(best);
      best = t;
    } else {
      t->Release();
    }
  }
  if (best) {
    reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, best);
  }
  IMFMediaType* rgb = nullptr;
  MFCreateMediaType(&rgb);
  rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (best) {
    UINT32 w = 0, h = 0;
    MFGetAttributeSize(best, MF_MT_FRAME_SIZE, &w, &h);
    MFSetAttributeSize(rgb, MF_MT_FRAME_SIZE, w, h);
  }
  hr = reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, rgb);
  rgb->Release();
  release(best);
  IMFMediaType* cur = nullptr;
  UINT32 w = 0, h = 0;
  if (SUCCEEDED(hr) && SUCCEEDED(reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &cur))) {
    MFGetAttributeSize(cur, MF_MT_FRAME_SIZE, &w, &h);
  }
  if (FAILED(hr) || !w || !h) {
    release(cur);
    reader->Release();
    src->Shutdown();
    src->Release();
    return false;
  }
  LONG stride = (LONG)MFGetAttributeUINT32(cur, MF_MT_DEFAULT_STRIDE, (UINT32)(w * 4));
  cur->Release();
  outW = (int)w;
  outH = (int)h;

  g_capturing = true;
  g_capture = std::thread([reader, src, w, h, stride]() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    std::vector<uint8_t> tmp((size_t)w * h * 4);
    while (g_capturing) {
      DWORD stream = 0, flags = 0;
      LONGLONG ts = 0;
      IMFSample* sample = nullptr;
      HRESULT r = reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &stream, &flags, &ts, &sample);
      if (FAILED(r) || (flags & (MF_SOURCE_READERF_ERROR | MF_SOURCE_READERF_ENDOFSTREAM))) {
        release(sample);
        say("error lost");
        break;
      }
      if (!sample) continue;
      IMFMediaBuffer* buf = nullptr;
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buf))) {
        BYTE* data = nullptr;
        LONG pitch = stride;
        IMF2DBuffer* b2 = nullptr;
        bool locked2 = false;
        if (SUCCEEDED(buf->QueryInterface(IID_PPV_ARGS(&b2))) && SUCCEEDED(b2->Lock2D(&data, &pitch))) {
          locked2 = true;
        } else {
          DWORD max = 0, len = 0;
          if (FAILED(buf->Lock(&data, &max, &len))) data = nullptr;
          if (data && stride < 0) data += (size_t)(-stride) * (h - 1);
        }
        if (data) {
          for (UINT32 y = 0; y < h; y++) {
            const BYTE* row = data + (LONG_PTR)pitch * (LONG_PTR)y;
            uint8_t* d = tmp.data() + (size_t)y * w * 4;
            std::memcpy(d, row, (size_t)w * 4);
            for (UINT32 x = 0; x < w; x++) d[x * 4 + 3] = 255;
          }
          std::lock_guard<std::mutex> l(g_frameLock);
          g_frame.w = (int)w;
          g_frame.h = (int)h;
          g_frame.bgra.swap(tmp);
          if (tmp.size() != (size_t)w * h * 4) tmp.resize((size_t)w * h * 4);
          g_frame.n++;
          if (locked2) {
            b2->Unlock2D();
          } else {
            buf->Unlock();
          }
        } else if (locked2) {
          b2->Unlock2D();
        }
        release(b2);
        buf->Release();
      }
      sample->Release();
    }
    reader->Release();
    src->Shutdown();
    src->Release();
    CoUninitialize();
  });
  return true;
}

// The camera's middle square, [side] x [side], mirrored or not (BGRA,
// alpha 255). False before the first frame.
bool squareOf(int side, bool mirror, std::vector<uint8_t>& out, uint64_t* frameNo = nullptr) {
  std::lock_guard<std::mutex> l(g_frameLock);
  const Frame& f = g_frame;
  if (!f.w || !f.h || f.bgra.empty()) return false;
  if (frameNo) *frameNo = f.n;
  out.resize((size_t)side * side * 4);
  const int sq = std::min(f.w, f.h);
  const double ox = (f.w - sq) / 2.0, oy = (f.h - sq) / 2.0;
  const double k = (double)sq / side;
  for (int y = 0; y < side; y++) {
    const double sy = oy + (y + 0.5) * k - 0.5;
    const int y0 = std::clamp((int)std::floor(sy), 0, f.h - 1), y1 = std::min(y0 + 1, f.h - 1);
    const double fy = std::clamp(sy - std::floor(sy), 0.0, 1.0);
    for (int x = 0; x < side; x++) {
      const int xx = mirror ? side - 1 - x : x;
      const double sx = ox + (xx + 0.5) * k - 0.5;
      const int x0 = std::clamp((int)std::floor(sx), 0, f.w - 1), x1 = std::min(x0 + 1, f.w - 1);
      const double fx = std::clamp(sx - std::floor(sx), 0.0, 1.0);
      const uint8_t* a = &f.bgra[((size_t)y0 * f.w + x0) * 4];
      const uint8_t* b = &f.bgra[((size_t)y0 * f.w + x1) * 4];
      const uint8_t* c = &f.bgra[((size_t)y1 * f.w + x0) * 4];
      const uint8_t* d = &f.bgra[((size_t)y1 * f.w + x1) * 4];
      uint8_t* o = &out[((size_t)y * side + x) * 4];
      for (int ch = 0; ch < 3; ch++) {
        const double top = a[ch] + (b[ch] - a[ch]) * fx, bot = c[ch] + (d[ch] - c[ch]) * fx;
        o[ch] = (uint8_t)std::lround(top + (bot - top) * fy);
      }
      o[3] = 255;
    }
  }
  return true;
}

// ---- The recording (frames to ffmpeg) ---------------------------------------

std::atomic<bool> g_recording{false};
std::atomic<bool> g_paused{false};
std::atomic<bool> g_mirror{true};
std::thread g_writer;
HANDLE g_ffIn = nullptr;
PROCESS_INFORMATION g_ff{};
std::atomic<uint64_t> g_written{0};

bool startRecording(int fps, int side, const std::string& cmd) {
  if (g_recording) return false;
  SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
  HANDLE rd = nullptr, wr = nullptr;
  if (!CreatePipe(&rd, &wr, &sa, 1 << 20)) return false;
  SetHandleInformation(wr, HANDLE_FLAG_INHERIT, 0);
  HANDLE nul = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, nullptr);
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = rd;
  si.hStdOutput = nul;
  si.hStdError = nul;
  std::wstring line = wide(cmd);
  const BOOL ok = CreateProcessW(nullptr, line.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &g_ff);
  CloseHandle(rd);
  if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
  if (!ok) {
    CloseHandle(wr);
    return false;
  }
  g_ffIn = wr;
  g_written = 0;
  g_paused = false;
  g_recording = true;
  g_writer = std::thread([fps, side]() {
    LARGE_INTEGER freq, last;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&last);
    double clock = 0;  // seconds recorded (paused time left out)
    std::vector<uint8_t> sq((size_t)side * side * 4, 0);
    std::vector<uint8_t> black((size_t)side * side * 4, 0);
    for (size_t i = 3; i < black.size(); i += 4) black[i] = 255;
    while (g_recording) {
      LARGE_INTEGER now;
      QueryPerformanceCounter(&now);
      const double dt = (double)(now.QuadPart - last.QuadPart) / freq.QuadPart;
      last = now;
      if (!g_paused) clock += dt;
      // Every frame due by now (the latest picture, repeated if need be).
      bool failed = false;
      while (!g_paused && (double)g_written / fps <= clock) {
        const bool have = squareOf(side, g_mirror, sq);
        const auto& src = have ? sq : black;
        DWORD put = 0;
        if (!WriteFile(g_ffIn, src.data(), (DWORD)src.size(), &put, nullptr) || put != src.size()) {
          failed = true;
          break;
        }
        g_written++;
      }
      if (failed) {
        say("error record");
        break;
      }
      Sleep(5);
    }
  });
  return true;
}

uint64_t stopRecording() {
  if (!g_recording && !g_writer.joinable()) return 0;
  g_recording = false;
  if (g_writer.joinable()) g_writer.join();
  if (g_ffIn) {
    CloseHandle(g_ffIn);
    g_ffIn = nullptr;
  }
  if (g_ff.hProcess) {
    if (WaitForSingleObject(g_ff.hProcess, 30000) != WAIT_OBJECT_0) TerminateProcess(g_ff.hProcess, 1);
    CloseHandle(g_ff.hProcess);
    CloseHandle(g_ff.hThread);
    g_ff = {};
  }
  return g_written;
}

// ---- The bubble ------------------------------------------------------------

HWND g_wnd = nullptr;
int g_x = 0, g_y = 0, g_side = 240;
bool g_round = true;
bool g_shown = false;
double g_dpi = 1.0;
uint64_t g_lastShown = ~0ull;
std::vector<uint8_t> g_sq;

// How far inside the shape (pixels; negative: outside).
double inside(double px, double py, int side, bool round) {
  const double c = side / 2.0;
  if (round) return c - std::hypot(px - c, py - c);
  const double r = side * 0.2;
  const double qx = std::fabs(px - c) - (c - r), qy = std::fabs(py - c) - (c - r);
  const double ox = std::max(qx, 0.0), oy = std::max(qy, 0.0);
  const double out = std::hypot(ox, oy) + std::min(std::max(qx, qy), 0.0) - r;
  return -out;
}

void paint() {
  if (!g_wnd || !g_shown) return;
  const int side = std::max(32, g_side);
  const bool have = squareOf(side, g_mirror, g_sq);
  if (!have) {
    g_sq.assign((size_t)side * side * 4, 0);
    for (size_t i = 0; i < g_sq.size(); i += 4) {
      g_sq[i] = 48;
      g_sq[i + 1] = 44;
      g_sq[i + 2] = 40;
      g_sq[i + 3] = 255;
    }
  }
  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
  bi.bmiHeader.biWidth = side;
  bi.bmiHeader.biHeight = -side;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  void* bits = nullptr;
  HBITMAP bmp = CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bmp && bits) {
    auto* d = static_cast<uint8_t*>(bits);
    const double edge = std::max(1.5, 2.0 * g_dpi);
    for (int y = 0; y < side; y++) {
      for (int x = 0; x < side; x++) {
        const double in = inside(x + 0.5, y + 0.5, side, g_round);
        const double all = std::clamp(in + 0.5, 0.0, 1.0);
        const double cam = std::clamp(in - edge + 0.5, 0.0, 1.0);
        const double ring = all - cam;
        const uint8_t* s = &g_sq[((size_t)y * side + x) * 4];
        uint8_t* o = &d[((size_t)y * side + x) * 4];
        for (int ch = 0; ch < 3; ch++) o[ch] = (uint8_t)std::lround(s[ch] * cam + 255.0 * ring);
        o[3] = (uint8_t)std::lround(255.0 * all);
      }
    }
    HGDIOBJ old = SelectObject(mem, bmp);
    POINT dst{g_x, g_y}, zero{0, 0};
    SIZE sz{side, side};
    BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(g_wnd, screen, &dst, &sz, mem, &zero, 0, &bf, ULW_ALPHA);
    SelectObject(mem, old);
  }
  if (bmp) DeleteObject(bmp);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
}

void reportPos() {
  std::ostringstream o;
  o << "pos " << g_x << ' ' << g_y << ' ' << g_side << ' ' << (g_round ? "round" : "square");
  say(o.str());
}

void command(const std::string& line) {
  std::istringstream in(line);
  std::string cmd;
  in >> cmd;
  if (cmd == "list") {
    for (auto& c : listCameras()) {
      say("camera " + c.first);
      c.second->Release();
    }
    say("end");
  } else if (cmd == "open") {
    std::string name;
    std::getline(in, name);
    if (!name.empty() && name[0] == ' ') name.erase(0, 1);
    std::string used;
    int w = 0, h = 0;
    bool none = false;
    if (openCamera(name, used, w, h, none)) {
      say("opened " + std::to_string(w) + " " + std::to_string(h) + " " + used);
    } else {
      say(none ? "error nocamera" : "error open");
    }
  } else if (cmd == "place") {
    int x = 0, y = 0, s = 0;
    in >> x >> y >> s;
    g_x = x;
    g_y = y;
    if (s > 0) g_side = s;
    paint();
  } else if (cmd == "dpi") {
    in >> g_dpi;
  } else if (cmd == "shape") {
    std::string v;
    in >> v;
    g_round = v != "square";
    paint();
  } else if (cmd == "mirror") {
    int v = 1;
    in >> v;
    g_mirror = v != 0;
  } else if (cmd == "show") {
    g_shown = true;
    ShowWindow(g_wnd, SW_SHOWNOACTIVATE);
    SetWindowPos(g_wnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    paint();
  } else if (cmd == "hide") {
    g_shown = false;
    ShowWindow(g_wnd, SW_HIDE);
  } else if (cmd == "record") {
    int fps = 30, side = 480;
    in >> fps >> side;
    std::string rest;
    std::getline(in, rest);
    if (!rest.empty() && rest[0] == ' ') rest.erase(0, 1);
    say(startRecording(std::clamp(fps, 5, 60), std::clamp(side, 64, 1080), rest) ? "recording" : "error record");
  } else if (cmd == "pause") {
    g_paused = true;
  } else if (cmd == "resume") {
    g_paused = false;
  } else if (cmd == "stoprec") {
    say("saved " + std::to_string(stopRecording()));
  } else if (cmd == "quit") {
    PostQuitMessage(0);
  }
}

LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) {
  switch (m) {
    case WM_NCHITTEST: {
      // Anywhere on it drags it (the see-through corners let clicks through).
      const LRESULT r = DefWindowProcW(h, m, w, l);
      return r == HTCLIENT ? HTCAPTION : r;
    }
    case WM_NCLBUTTONDBLCLK:
      g_round = !g_round;
      paint();
      reportPos();
      return 0;
    case WM_NCRBUTTONUP:
      return 0;
    case WM_MOVING: {
      const RECT* r = reinterpret_cast<RECT*>(l);
      g_x = r->left;
      g_y = r->top;
      return TRUE;
    }
    case WM_EXITSIZEMOVE: {
      RECT r{};
      GetWindowRect(h, &r);
      g_x = r.left;
      g_y = r.top;
      reportPos();
      return 0;
    }
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_TIMER:
      if (w == kTimer && g_shown) {
        uint64_t n = 0;
        {
          std::lock_guard<std::mutex> lk(g_frameLock);
          n = g_frame.n;
        }
        if (n != g_lastShown) {
          g_lastShown = n;
          paint();
        }
        // Stays above everything (the pen's layer too).
        static int k = 0;
        if (++k % 30 == 0) SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      }
      return 0;
    case WM_CMD: {
      auto* s = reinterpret_cast<std::string*>(l);
      command(*s);
      delete s;
      return 0;
    }
    default:
      return DefWindowProcW(h, m, w, l);
  }
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(MFStartup(MF_VERSION))) {
    say("error mf");
    return 1;
  }
  WNDCLASSW wc{};
  wc.style = CS_DBLCLKS;
  wc.lpfnWndProc = proc;
  wc.hInstance = inst;
  wc.hCursor = LoadCursorW(nullptr, IDC_SIZEALL);
  wc.lpszClassName = L"LocalRollCamera";
  RegisterClassW(&wc);
  g_wnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, wc.lpszClassName, L"Keepnear camera",
                          WS_POPUP, 0, 0, g_side, g_side, nullptr, nullptr, inst, nullptr);
  if (!g_wnd) {
    say("error window");
    return 1;
  }
  SetTimer(g_wnd, kTimer, 15, nullptr);
  const DWORD mainThread = GetCurrentThreadId();
  std::thread reader([mainThread]() {
    std::string line;
    while (std::getline(std::cin, line)) {
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.empty()) continue;
      PostMessageW(g_wnd, WM_CMD, 0, reinterpret_cast<LPARAM>(new std::string(line)));
      if (line == "quit") return;
    }
    PostThreadMessageW(mainThread, WM_QUIT, 0, 0);
    PostMessageW(g_wnd, WM_CMD, 0, reinterpret_cast<LPARAM>(new std::string("quit")));
  });
  reader.detach();
  say("ready");
  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  stopRecording();
  stopCamera();
  DestroyWindow(g_wnd);
  MFShutdown();
  CoUninitialize();
  return 0;
}
