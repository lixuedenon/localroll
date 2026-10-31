// apps/desktop/windows/overlay/overlay.cpp
//
// LocalRoll's screen pen: a transparent layer over every screen. What is
// drawn shows on the real screen (so a screen recording simply records
// it), and in "operate" mode the mouse passes straight through to the
// apps underneath while the marks stay. One page of marks per window: the
// marks of a window show only while that window is in use.
//
// LocalRoll drives it through stdin / stdout, one command per line (UTF-8):
//   own <hwnd>            LocalRoll's window (never a page; its own UI)
//   page <hwnd>           start on this window's page
//   mode draw|operate     draw on the layer / let the mouse through
//   tool <name>           pen marker line arrow rect ellipse text check
//                         cross number select eraser
//   color <AARRGGBB>      level 0|1|2
//   undo  redo  clear  delete  newpage  prevpage  nextpage
//   board none|white|black  highlight 0|1  fade 0|1  autoreturn 0|1
//   pendraw 0|1           a pen (stylus) draws even in operate mode
//   togglekey <vk>        this key switches draw / operate (0: none);
//                         the key is not passed on to the app in front
//   text <x> <y> <words>  put words at x, y (screen pixels)
//   border <x> <y> <w> <h> | border off   red frame around an area
//   visible 0|1           quit
//   probe <x> <y>         answers "pixel AARRGGBB" (a self-check)
// It answers:
//   ready <x> <y> <w> <h>                   the screens it covers
//   state <mode> <undo> <redo> <selected> <sheet> <sheets>
//   text <x> <y>                            the text tool was clicked there
// Closing stdin ends it too.

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <map>
#include <string>
#include <thread>
#include <vector>

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace {

template <class T>
struct Com {
  T* p = nullptr;
  Com() = default;
  Com(const Com&) = delete;
  Com& operator=(const Com&) = delete;
  Com(Com&& o) noexcept : p(o.p) { o.p = nullptr; }
  Com& operator=(Com&& o) noexcept {
    if (this != &o) {
      reset();
      p = o.p;
      o.p = nullptr;
    }
    return *this;
  }
  ~Com() { reset(); }
  void reset() {
    if (p) p->Release();
    p = nullptr;
  }
  T** put() {
    reset();
    return &p;
  }
  T* operator->() const { return p; }
  explicit operator bool() const { return p != nullptr; }
};

constexpr UINT kCmd = WM_APP + 1;
constexpr UINT kQuit = WM_APP + 2;
constexpr UINT_PTR kTimerTick = 1;
constexpr UINT_PTR kTimerCursor = 2;
constexpr float kPi = 3.14159265358979f;

enum Tool { kPen, kMarker, kLine, kArrow, kRect, kEllipse, kText, kCheck, kCross, kNumber, kSelect, kEraser };

const wchar_t* const kToolNames[] = {L"pen", L"marker", L"line", L"arrow", L"rect", L"ellipse", L"text",
                                     L"check", L"cross", L"number", L"select", L"eraser"};

struct Mark {
  int id = 0;
  int tool = kPen;
  UINT32 argb = 0xFFFF3B30;
  float width = 6;   // line width (pixels)
  float size = 36;   // text / stamp size (pixels)
  std::vector<D2D1_POINT_2F> pts;
  std::wstring text;
  int number = 0;
  float dx = 0, dy = 0, scale = 1, rot = 0;  // rot in degrees
  ULONGLONG doneAt = 0;
  bool fades = false;
};

struct Sheet {
  std::vector<Mark> marks;
  std::vector<std::vector<Mark>> undo, redo;
};

struct Page {
  std::vector<Sheet> sheets = std::vector<Sheet>(1);
  int cur = 0;
  Sheet& sheet() { return sheets[cur]; }
};

// ---------------------------------------------------------------- state

HINSTANCE g_inst;
HWND g_msg = nullptr, g_layer = nullptr, g_spot = nullptr, g_frame = nullptr;
HWND g_own = nullptr;
RECT g_virt{};  // all screens, pixels
std::map<HWND, Page> g_pages;
HWND g_page = nullptr;
bool g_draw = false, g_pass = false, g_visible = true;
int g_tool = kPen, g_level = 1, g_nextId = 1, g_nextNumber = 1;
UINT32 g_color = 0xFFFF3B30;
bool g_fade = false, g_autoReturn = false, g_penDraw = true, g_highlight = false;
int g_board = 0;  // 0 none, 1 white, 2 black
RECT g_boardRect{};
int g_selected = 0;

// What a drag does.
enum Drag { kNone, kDrawing, kErasing, kMoving, kScaling, kRotating };
Drag g_drag = kNone;
Mark g_draft;
bool g_hasDraft = false;
D2D1_POINT_2F g_from{};
Mark g_start;
int g_made = 0;
ULONGLONG g_lastDown = 0;
POINT g_lastAt{};
bool g_penDown = false;

// Drawing.
Com<ID2D1Factory> g_d2d;
Com<IDWriteFactory> g_dw;
Com<ID2D1DCRenderTarget> g_rt;
HDC g_dc = nullptr;
HBITMAP g_dib = nullptr;
UINT32* g_bits = nullptr;
HGDIOBJ g_oldBmp = nullptr;
HHOOK g_hook = nullptr, g_keys = nullptr;
int g_toggleKey = VK_F8;
bool g_keyHeld = false;
ULONGLONG g_lastWheel = 0;
HWINEVENTHOOK g_fgHook = nullptr;

Page& page() { return g_pages[g_page]; }
Sheet& sheet() { return page().sheet(); }

void emit(const std::string& line) {
  std::fputs(line.c_str(), stdout);
  std::fputc('\n', stdout);
  std::fflush(stdout);
}

void emitState() {
  Page& p = page();
  Sheet& s = p.sheet();
  char b[160];
  std::snprintf(b, sizeof b, "state %s %d %d %d %d %d", g_draw ? "draw" : "operate", s.undo.empty() ? 0 : 1,
                s.redo.empty() ? 0 : 1, g_selected != 0 ? 1 : 0, p.cur + 1, static_cast<int>(p.sheets.size()));
  emit(b);
}

float dpiScaleAt(POINT pt) {
  using Fn = HRESULT(WINAPI*)(HMONITOR, int, UINT*, UINT*);
  static Fn fn = reinterpret_cast<Fn>(reinterpret_cast<void*>(GetProcAddress(LoadLibraryW(L"shcore.dll"), "GetDpiForMonitor")));
  UINT x = 96, y = 96;
  if (fn) fn(MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST), 0, &x, &y);
  return x / 96.0f;
}

D2D1_COLOR_F colorOf(UINT32 argb, float alpha = 1) {
  return D2D1::ColorF(((argb >> 16) & 0xFF) / 255.0f, ((argb >> 8) & 0xFF) / 255.0f, (argb & 0xFF) / 255.0f,
                      ((argb >> 24) & 0xFF) / 255.0f * alpha);
}

// ---------------------------------------------------------------- geometry

Com<IDWriteTextLayout> textLayout(const Mark& m) {
  Com<IDWriteTextFormat> fmt;
  Com<IDWriteTextLayout> lay;
  g_dw->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL,
                         DWRITE_FONT_STRETCH_NORMAL, m.size, L"", fmt.put());
  if (fmt) g_dw->CreateTextLayout(m.text.c_str(), static_cast<UINT32>(m.text.size()), fmt.p, 4000, 4000, lay.put());
  return lay;
}

// The mark's own box (before moving / turning / scaling).
D2D1_RECT_F rawBox(const Mark& m) {
  if (m.pts.empty()) return D2D1::RectF();
  const auto p0 = m.pts[0];
  if (m.tool == kText) {
    auto lay = textLayout(m);
    DWRITE_TEXT_METRICS tm{};
    if (lay) lay->GetMetrics(&tm);
    return D2D1::RectF(p0.x, p0.y, p0.x + std::max(tm.widthIncludingTrailingWhitespace, m.size * 0.5f),
                       p0.y + std::max(tm.height, m.size));
  }
  if (m.tool == kCheck || m.tool == kCross || m.tool == kNumber) {
    const float h = m.size * 0.5f;
    return D2D1::RectF(p0.x - h, p0.y - h, p0.x + h, p0.y + h);
  }
  float l = p0.x, t = p0.y, r = p0.x, b = p0.y;
  for (const auto& p : m.pts) {
    l = std::min(l, p.x);
    t = std::min(t, p.y);
    r = std::max(r, p.x);
    b = std::max(b, p.y);
  }
  const float pad = m.tool == kArrow ? std::max(12.0f, m.width * 4) : m.width / 2;
  return D2D1::RectF(l - pad, t - pad, r + pad, b + pad);
}

D2D1::Matrix3x2F transformOf(const Mark& m) {
  const auto b = rawBox(m);
  const D2D1_POINT_2F c = D2D1::Point2F((b.left + b.right) / 2, (b.top + b.bottom) / 2);
  return D2D1::Matrix3x2F::Scale(m.scale, m.scale, c) * D2D1::Matrix3x2F::Rotation(m.rot, c) *
         D2D1::Matrix3x2F::Translation(m.dx, m.dy);
}

D2D1_POINT_2F centerOf(const Mark& m) {
  const auto b = rawBox(m);
  return transformOf(m).TransformPoint(D2D1::Point2F((b.left + b.right) / 2, (b.top + b.bottom) / 2));
}

// The outline to stroke for lines and shapes (null for text / stamps).
Com<ID2D1Geometry> outline(const Mark& m) {
  Com<ID2D1Geometry> g;
  if (m.pts.empty()) return g;
  const auto a = m.pts.front(), z = m.pts.back();
  switch (m.tool) {
    case kRect: {
      Com<ID2D1RectangleGeometry> r;
      g_d2d->CreateRectangleGeometry(D2D1::RectF(std::min(a.x, z.x), std::min(a.y, z.y), std::max(a.x, z.x), std::max(a.y, z.y)),
                                     r.put());
      if (r) r->QueryInterface(__uuidof(ID2D1Geometry), reinterpret_cast<void**>(g.put()));
      return g;
    }
    case kEllipse: {
      Com<ID2D1EllipseGeometry> e;
      g_d2d->CreateEllipseGeometry(
          D2D1::Ellipse(D2D1::Point2F((a.x + z.x) / 2, (a.y + z.y) / 2), std::fabs(z.x - a.x) / 2, std::fabs(z.y - a.y) / 2), e.put());
      if (e) e->QueryInterface(__uuidof(ID2D1Geometry), reinterpret_cast<void**>(g.put()));
      return g;
    }
    case kPen:
    case kMarker:
    case kLine:
    case kArrow:
    case kCheck:
    case kCross: {
      Com<ID2D1PathGeometry> path;
      g_d2d->CreatePathGeometry(path.put());
      if (!path) return g;
      Com<ID2D1GeometrySink> sink;
      path->Open(sink.put());
      auto line = [&](std::initializer_list<D2D1_POINT_2F> ps) {
        auto it = ps.begin();
        sink->BeginFigure(*it, D2D1_FIGURE_BEGIN_HOLLOW);
        for (++it; it != ps.end(); ++it) sink->AddLine(*it);
        sink->EndFigure(D2D1_FIGURE_END_OPEN);
      };
      if (m.tool == kCheck) {
        const float s = m.size;
        line({D2D1::Point2F(a.x - s * 0.35f, a.y), D2D1::Point2F(a.x - s * 0.1f, a.y + s * 0.28f),
              D2D1::Point2F(a.x + s * 0.4f, a.y - s * 0.32f)});
      } else if (m.tool == kCross) {
        const float s = m.size * 0.32f;
        line({D2D1::Point2F(a.x - s, a.y - s), D2D1::Point2F(a.x + s, a.y + s)});
        line({D2D1::Point2F(a.x + s, a.y - s), D2D1::Point2F(a.x - s, a.y + s)});
      } else if (m.tool == kLine || m.tool == kArrow) {
        line({a, z});
        if (m.tool == kArrow) {
          const float len = std::max(12.0f, m.width * 4), ang = std::atan2(z.y - a.y, z.x - a.x);
          for (float s : {1.0f, -1.0f}) {
            const float t = ang + kPi + s * 0.5f;
            line({z, D2D1::Point2F(z.x + len * std::cos(t), z.y + len * std::sin(t))});
          }
        }
      } else {
        sink->BeginFigure(a, D2D1_FIGURE_BEGIN_HOLLOW);
        if (m.pts.size() == 1) {
          sink->AddLine(D2D1::Point2F(a.x + 0.01f, a.y + 0.01f));
        } else {
          for (size_t i = 1; i < m.pts.size(); ++i) sink->AddLine(m.pts[i]);
        }
        sink->EndFigure(D2D1_FIGURE_END_OPEN);
      }
      sink->Close();
      path->QueryInterface(__uuidof(ID2D1Geometry), reinterpret_cast<void**>(g.put()));
      return g;
    }
    default:
      return g;
  }
}

Com<ID2D1StrokeStyle> roundStroke() {
  Com<ID2D1StrokeStyle> st;
  g_d2d->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
                                                       D2D1_LINE_JOIN_ROUND),
                           nullptr, 0, st.put());
  return st;
}

float lineWidth(const Mark& m) { return m.tool == kMarker ? m.width * 4 : (m.tool == kCheck || m.tool == kCross) ? m.size * 0.12f : m.width; }

float dist(D2D1_POINT_2F a, D2D1_POINT_2F b) { return std::sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)); }

// The lines a mark is made of (its own coordinates), for touching it.
std::vector<std::vector<D2D1_POINT_2F>> linesOf(const Mark& m) {
  std::vector<std::vector<D2D1_POINT_2F>> out;
  if (m.pts.empty()) return out;
  const auto a = m.pts.front(), z = m.pts.back();
  switch (m.tool) {
    case kRect:
      out.push_back({a, D2D1::Point2F(z.x, a.y), z, D2D1::Point2F(a.x, z.y), a});
      break;
    case kEllipse: {
      std::vector<D2D1_POINT_2F> e;
      const float cx = (a.x + z.x) / 2, cy = (a.y + z.y) / 2, rx = std::fabs(z.x - a.x) / 2, ry = std::fabs(z.y - a.y) / 2;
      for (int i = 0; i <= 48; ++i) {
        const float t = i * 2 * kPi / 48;
        e.push_back(D2D1::Point2F(cx + rx * std::cos(t), cy + ry * std::sin(t)));
      }
      out.push_back(e);
      break;
    }
    case kLine:
    case kArrow:
      out.push_back({a, z});
      break;
    case kCheck: {
      const float s = m.size;
      out.push_back({D2D1::Point2F(a.x - s * 0.35f, a.y), D2D1::Point2F(a.x - s * 0.1f, a.y + s * 0.28f),
                     D2D1::Point2F(a.x + s * 0.4f, a.y - s * 0.32f)});
      break;
    }
    case kCross: {
      const float s = m.size * 0.32f;
      out.push_back({D2D1::Point2F(a.x - s, a.y - s), D2D1::Point2F(a.x + s, a.y + s)});
      out.push_back({D2D1::Point2F(a.x + s, a.y - s), D2D1::Point2F(a.x - s, a.y + s)});
      break;
    }
    default:
      out.push_back(m.pts);
  }
  return out;
}

float segDist(D2D1_POINT_2F p, D2D1_POINT_2F a, D2D1_POINT_2F b) {
  const float vx = b.x - a.x, vy = b.y - a.y, len2 = vx * vx + vy * vy;
  float t = len2 > 0 ? ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2 : 0;
  t = std::clamp(t, 0.0f, 1.0f);
  const float x = a.x + t * vx - p.x, y = a.y + t * vy - p.y;
  return std::sqrt(x * x + y * y);
}

// Whether [p] (screen pixels) touches mark [m].
bool hits(const Mark& m, D2D1_POINT_2F p, float slop) {
  auto inv = transformOf(m);
  if (!inv.Invert()) return false;
  const auto q = inv.TransformPoint(p);
  slop /= std::max(0.1f, m.scale);
  if (m.tool == kText || m.tool == kNumber) {
    const auto b = rawBox(m);
    return q.x >= b.left - slop && q.x <= b.right + slop && q.y >= b.top - slop && q.y <= b.bottom + slop;
  }
  const float reach = lineWidth(m) / 2 + slop;
  for (const auto& line : linesOf(m)) {
    if (line.size() == 1 && dist(q, line[0]) <= reach) return true;
    for (size_t i = 1; i < line.size(); ++i) {
      if (segDist(q, line[i - 1], line[i]) <= reach) return true;
    }
  }
  return false;
}

// Inside a mark's box (a selected mark is dragged from anywhere in it).
bool insideBox(const Mark& m, D2D1_POINT_2F p) {
  auto inv = transformOf(m);
  if (!inv.Invert()) return false;
  const auto q = inv.TransformPoint(p);
  const auto b = rawBox(m);
  return q.x >= b.left && q.x <= b.right && q.y >= b.top && q.y <= b.bottom;
}

Mark* findMark(int id) {
  for (auto& m : sheet().marks) {
    if (m.id == id) return &m;
  }
  return nullptr;
}

Mark* topAt(D2D1_POINT_2F p) {
  auto& ms = sheet().marks;
  for (auto it = ms.rbegin(); it != ms.rend(); ++it) {
    if (hits(*it, p, 8)) return &*it;
  }
  return nullptr;
}

// The four corners and the turning knob of a selected mark (screen pixels).
void handles(const Mark& m, D2D1_POINT_2F corners[4], D2D1_POINT_2F& knob) {
  const auto b = rawBox(m);
  const auto t = transformOf(m);
  corners[0] = t.TransformPoint(D2D1::Point2F(b.left, b.top));
  corners[1] = t.TransformPoint(D2D1::Point2F(b.right, b.top));
  corners[2] = t.TransformPoint(D2D1::Point2F(b.right, b.bottom));
  corners[3] = t.TransformPoint(D2D1::Point2F(b.left, b.bottom));
  const D2D1_POINT_2F top = D2D1::Point2F((corners[0].x + corners[1].x) / 2, (corners[0].y + corners[1].y) / 2);
  const auto c = centerOf(m);
  const float dx = top.x - c.x, dy = top.y - c.y, len = std::max(1.0f, std::sqrt(dx * dx + dy * dy));
  knob = D2D1::Point2F(top.x + dx / len * 26, top.y + dy / len * 26);
}


// ---------------------------------------------------------------- painting

float fadeAlpha(const Mark& m, ULONGLONG now) {
  if (!m.fades || m.doneAt == 0) return 1;
  const ULONGLONG age = now - m.doneAt;
  if (age < 3000) return 1;
  return std::max(0.0f, 1.0f - static_cast<float>(age - 3000) / 500.0f);
}

void present(const RECT* dirty) {
  POINT src{0, 0}, dst{g_virt.left, g_virt.top};
  SIZE size{g_virt.right - g_virt.left, g_virt.bottom - g_virt.top};
  BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UPDATELAYEREDWINDOWINFO info{};
  info.cbSize = sizeof info;
  info.hdcSrc = g_dc;
  info.pptDst = &dst;
  info.psize = &size;
  info.pptSrc = &src;
  info.pblend = &bf;
  info.dwFlags = ULW_ALPHA;
  info.prcDirty = dirty;
  // Only the changed part when it can; else the whole layer.
  if (!dirty || !UpdateLayeredWindowIndirect(g_layer, &info)) {
    UpdateLayeredWindow(g_layer, nullptr, &dst, &size, g_dc, &src, 0, &bf, ULW_ALPHA);
  }
}

// Paints [dirty] (layer pixels; null: everything) and shows it.
void render(const RECT* dirty = nullptr) {
  if (!g_rt) return;
  const LONG w = g_virt.right - g_virt.left, h = g_virt.bottom - g_virt.top;
  RECT all{0, 0, w, h};
  RECT d = dirty ? *dirty : all;
  IntersectRect(&d, &d, &all);
  if (IsRectEmpty(&d)) return;
  RECT bind{0, 0, w, h};
  g_rt->BindDC(g_dc, &bind);
  g_rt->BeginDraw();
  g_rt->SetTransform(D2D1::Matrix3x2F::Identity());
  g_rt->PushAxisAlignedClip(D2D1::RectF(static_cast<float>(d.left), static_cast<float>(d.top), static_cast<float>(d.right),
                                        static_cast<float>(d.bottom)),
                            D2D1_ANTIALIAS_MODE_ALIASED);
  // Drawing: almost invisible everywhere, so every click lands here.
  g_rt->Clear(D2D1::ColorF(0, 0, 0, g_draw && !g_pass ? 1.0f / 255 : 0));
  // Everything is drawn in layer pixels: the layer starts at the screens' corner.
  const auto shift = D2D1::Matrix3x2F::Translation(static_cast<float>(-g_virt.left), static_cast<float>(-g_virt.top));
  if (g_board && g_visible) {
    Com<ID2D1SolidColorBrush> bb;
    g_rt->CreateSolidColorBrush(g_board == 1 ? D2D1::ColorF(0xFAFAF7) : D2D1::ColorF(0x1E2A24), bb.put());
    if (bb) {
      g_rt->SetTransform(shift);
      g_rt->FillRectangle(D2D1::RectF(static_cast<float>(g_boardRect.left), static_cast<float>(g_boardRect.top),
                                      static_cast<float>(g_boardRect.right), static_cast<float>(g_boardRect.bottom)),
                          bb.p);
    }
  }
  if (g_visible) {
    auto round = roundStroke();
    const ULONGLONG now = GetTickCount64();
    // Each mark with its own move / turn / scale, then into layer pixels.
    auto paintAll = [&](const Mark& m, float alpha) {
      g_rt->SetTransform(transformOf(m) * shift);
      Com<ID2D1SolidColorBrush> br;
      const float a = alpha * (m.tool == kMarker ? 0.38f : 1.0f);
      g_rt->CreateSolidColorBrush(colorOf(m.argb, a), br.put());
      if (!br) return;
      if (m.tool == kText) {
        auto lay = textLayout(m);
        if (lay) g_rt->DrawTextLayout(m.pts[0], lay.p, br.p);
      } else if (m.tool == kNumber) {
        const auto p = m.pts[0];
        const float r = m.size * 0.45f;
        g_rt->FillEllipse(D2D1::Ellipse(p, r, r), br.p);
        Com<ID2D1SolidColorBrush> white;
        g_rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, alpha), white.put());
        Com<IDWriteTextFormat> fmt;
        g_dw->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                               m.size * 0.5f, L"", fmt.put());
        if (fmt && white) {
          fmt->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
          fmt->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
          const std::wstring n = std::to_wstring(m.number);
          g_rt->DrawText(n.c_str(), static_cast<UINT32>(n.size()), fmt.p, D2D1::RectF(p.x - r, p.y - r, p.x + r, p.y + r), white.p);
        }
      } else {
        auto g = outline(m);
        if (g) g_rt->DrawGeometry(g.p, br.p, lineWidth(m), round.p);
      }
    };
    for (const auto& m : sheet().marks) paintAll(m, fadeAlpha(m, now));
    if (g_hasDraft) paintAll(g_draft, 1);
    g_rt->SetTransform(shift);
    if (const Mark* s = findMark(g_selected)) {
      // Handles in screen pixels, shifted.
      D2D1_POINT_2F c[4], knob;
      handles(*s, c, knob);
      Com<ID2D1SolidColorBrush> br, fill;
      g_rt->CreateSolidColorBrush(D2D1::ColorF(0x2F8CFF), br.put());
      g_rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 1), fill.put());
      Com<ID2D1StrokeStyle> dash;
      g_d2d->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT,
                                                           D2D1_LINE_JOIN_MITER, 10, D2D1_DASH_STYLE_DASH),
                               nullptr, 0, dash.put());
      if (br && fill) {
        for (int i = 0; i < 4; ++i) g_rt->DrawLine(c[i], c[(i + 1) % 4], br.p, 1.5f, dash.p);
        const D2D1_POINT_2F top = D2D1::Point2F((c[0].x + c[1].x) / 2, (c[0].y + c[1].y) / 2);
        g_rt->DrawLine(top, knob, br.p, 1.5f);
        for (auto p : c) {
          const auto r = D2D1::RectF(p.x - 5, p.y - 5, p.x + 5, p.y + 5);
          g_rt->FillRectangle(r, fill.p);
          g_rt->DrawRectangle(r, br.p, 1.5f);
        }
        g_rt->FillEllipse(D2D1::Ellipse(knob, 6, 6), fill.p);
        g_rt->DrawEllipse(D2D1::Ellipse(knob, 6, 6), br.p, 1.5f);
      }
    }
  }
  g_rt->SetTransform(D2D1::Matrix3x2F::Identity());
  g_rt->PopAxisAlignedClip();
  if (g_rt->EndDraw() == static_cast<HRESULT>(D2DERR_RECREATE_TARGET)) {
    g_rt.reset();
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
    g_d2d->CreateDCRenderTarget(&props, g_rt.put());
  }
  present(dirty ? &d : nullptr);
}

// The layer pixels a mark covers (with room for its handles).
RECT areaOf(const Mark& m) {
  D2D1_POINT_2F c[4], knob;
  handles(m, c, knob);
  float l = knob.x, t = knob.y, r = knob.x, b = knob.y;
  for (auto p : c) {
    l = std::min(l, p.x);
    t = std::min(t, p.y);
    r = std::max(r, p.x);
    b = std::max(b, p.y);
  }
  const float pad = lineWidth(m) * 2 + 16;
  return RECT{static_cast<LONG>(l - pad) - g_virt.left, static_cast<LONG>(t - pad) - g_virt.top,
              static_cast<LONG>(r + pad) - g_virt.left, static_cast<LONG>(b + pad) - g_virt.top};
}

// ---------------------------------------------------------------- the layer window

void setPassThrough() {
  const bool through = !g_draw || g_pass;
  LONG_PTR ex = GetWindowLongPtrW(g_layer, GWL_EXSTYLE);
  const LONG_PTR want = through ? (ex | WS_EX_TRANSPARENT) : (ex & ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT));
  if (want != ex) {
    SetWindowLongPtrW(g_layer, GWL_EXSTYLE, want);
    SetWindowPos(g_layer, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }
}

void setMode(bool draw) {
  if (g_draw == draw) return;
  g_draw = draw;
  g_pass = false;
  if (!draw && g_drag != kNone) {
    g_drag = kNone;
    g_hasDraft = false;
    ReleaseCapture();
  }
  setPassThrough();
  render();
  emitState();
}

void remember() {
  auto& s = sheet();
  s.undo.push_back(s.marks);
  if (s.undo.size() > 100) s.undo.erase(s.undo.begin());
  s.redo.clear();
}

void select(int id) {
  const Mark* old = findMark(g_selected);
  RECT a{};
  if (old) a = areaOf(*old);
  g_selected = id;
  if (const Mark* m = findMark(id)) {
    RECT b = areaOf(*m);
    if (old) UnionRect(&a, &a, &b); else a = b;
  }
  if (!IsRectEmpty(&a)) render(&a);
  emitState();
}

void deleteSelected() {
  if (!findMark(g_selected)) return;
  remember();
  auto& ms = sheet().marks;
  ms.erase(std::remove_if(ms.begin(), ms.end(), [](const Mark& m) { return m.id == g_selected; }), ms.end());
  g_selected = 0;
  render();
  emitState();
}

// Takes back the mark a click just made (the first click of a double-click).
void dropMade(int id) {
  auto& s = sheet();
  auto it = std::find_if(s.marks.begin(), s.marks.end(), [id](const Mark& m) { return m.id == id; });
  if (it == s.marks.end()) return;
  if (it->tool == kNumber) g_nextNumber = it->number;
  s.marks.erase(it);
  if (!s.undo.empty()) s.undo.pop_back();
}

Mark newMark(int tool, D2D1_POINT_2F p) {
  Mark m;
  m.id = g_nextId++;
  m.tool = tool;
  m.argb = g_color;
  POINT sp{static_cast<LONG>(p.x), static_cast<LONG>(p.y)};
  const float k = dpiScaleAt(sp);
  const float widths[] = {3, 6, 12};
  const float sizes[] = {24, 36, 54};
  const float stamps[] = {28, 40, 60};
  m.width = widths[g_level] * k;
  m.size = (tool == kText ? sizes[g_level] : stamps[g_level]) * k;
  m.pts.push_back(p);
  m.fades = g_fade;
  return m;
}

void endDrawing() {
  if (!g_hasDraft) return;
  g_hasDraft = false;
  Mark m = g_draft;
  const bool tiny = m.tool != kPen && m.tool != kMarker && m.pts.size() >= 2 && dist(m.pts.front(), m.pts.back()) < 3;
  if (!tiny) {
    remember();
    m.doneAt = GetTickCount64();
    sheet().marks.push_back(m);
  } else {
    g_made = 0;
  }
  render();
  emitState();
  if (g_autoReturn) setMode(false);
}

void onDown(D2D1_POINT_2F p) {
  const ULONGLONG now = GetTickCount64();
  POINT pt{static_cast<LONG>(p.x), static_cast<LONG>(p.y)};
  const bool twice = now - g_lastDown < 400 && std::abs(pt.x - g_lastAt.x) < 8 && std::abs(pt.y - g_lastAt.y) < 8;
  g_lastDown = now;
  g_lastAt = pt;
  const int made = g_made;
  g_made = 0;
  if (twice && g_tool != kText) {
    if (made) dropMade(made);
    if (Mark* hit = topAt(p)) {
      if (hit->id == g_selected) {
        deleteSelected();
        g_lastDown = 0;
      } else {
        select(hit->id);
        render();
      }
      g_drag = kNone;
      return;
    }
    render();
  }
  // Something selected: drag it, its corners or knob; elsewhere lets it go.
  if (Mark* s = findMark(g_selected)) {
    D2D1_POINT_2F c[4], knob;
    handles(*s, c, knob);
    Drag d = kNone;
    if (dist(p, knob) < 12) {
      d = kRotating;
    } else if (std::any_of(c, c + 4, [&](D2D1_POINT_2F q) { return dist(p, q) < 10; })) {
      d = kScaling;
    } else if (insideBox(*s, p) || hits(*s, p, 8)) {
      d = kMoving;
    }
    if (d != kNone) {
      remember();
      g_drag = d;
      g_from = p;
      g_start = *s;
      return;
    }
    if (g_tool != kSelect) {
      select(0);
      return;
    }
    select(0);
  }
  switch (g_tool) {
    case kEraser:
      g_drag = kErasing;
      if (Mark* hit = topAt(p)) {
        remember();
        const int id = hit->id;
        auto& ms = sheet().marks;
        ms.erase(std::remove_if(ms.begin(), ms.end(), [id](const Mark& m) { return m.id == id; }), ms.end());
        render();
        emitState();
      }
      return;
    case kSelect:
      if (Mark* hit = topAt(p)) {
        select(hit->id);
        remember();
        g_drag = kMoving;
        g_from = p;
        g_start = *hit;
      }
      return;
    case kText: {
      char b[64];
      std::snprintf(b, sizeof b, "text %ld %ld", pt.x, pt.y);
      emit(b);
      return;
    }
    case kCheck:
    case kCross:
    case kNumber: {
      remember();
      Mark m = newMark(g_tool, p);
      if (g_tool == kNumber) m.number = g_nextNumber++;
      m.doneAt = now;
      sheet().marks.push_back(m);
      g_made = m.id;
      RECT a = areaOf(m);
      render(&a);
      emitState();
      if (g_autoReturn) setMode(false);
      return;
    }
    default:
      g_draft = newMark(g_tool, p);
      if (g_tool != kPen && g_tool != kMarker) g_draft.pts.push_back(p);
      g_hasDraft = true;
      g_made = g_draft.id;
      g_drag = kDrawing;
      return;
  }
}

void onMove(D2D1_POINT_2F p) {
  const bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
  switch (g_drag) {
    case kDrawing: {
      auto& d = g_draft;
      RECT before = areaOf(d);
      if (d.tool == kPen || d.tool == kMarker) {
        if (dist(d.pts.back(), p) < 1.5f) return;
        const auto last = d.pts.back();
        d.pts.push_back(p);
        const float pad = lineWidth(d) + 4;
        RECT r{static_cast<LONG>(std::min(last.x, p.x) - pad) - g_virt.left, static_cast<LONG>(std::min(last.y, p.y) - pad) - g_virt.top,
               static_cast<LONG>(std::max(last.x, p.x) + pad) - g_virt.left, static_cast<LONG>(std::max(last.y, p.y) + pad) - g_virt.top};
        render(&r);
        return;
      }
      auto to = p;
      if (shift) {
        const auto a = d.pts.front();
        const float vx = p.x - a.x, vy = p.y - a.y;
        if (d.tool == kRect || d.tool == kEllipse) {
          const float m = std::max(std::fabs(vx), std::fabs(vy));
          to = D2D1::Point2F(a.x + (vx < 0 ? -m : m), a.y + (vy < 0 ? -m : m));
        } else {
          const float ang = std::round(std::atan2(vy, vx) / (kPi / 4)) * (kPi / 4), len = std::sqrt(vx * vx + vy * vy);
          to = D2D1::Point2F(a.x + std::cos(ang) * len, a.y + std::sin(ang) * len);
        }
      }
      d.pts.back() = to;
      RECT after = areaOf(d);
      UnionRect(&before, &before, &after);
      render(&before);
      return;
    }
    case kErasing:
      if (Mark* hit = topAt(p)) {
        const int id = hit->id;
        auto& ms = sheet().marks;
        ms.erase(std::remove_if(ms.begin(), ms.end(), [id](const Mark& m) { return m.id == id; }), ms.end());
        render();
        emitState();
      }
      return;
    case kMoving:
    case kScaling:
    case kRotating: {
      Mark* s = findMark(g_selected);
      if (!s) return;
      RECT before = areaOf(*s);
      const auto c = centerOf(g_start);
      if (g_drag == kMoving) {
        s->dx = g_start.dx + (p.x - g_from.x);
        s->dy = g_start.dy + (p.y - g_from.y);
      } else if (g_drag == kScaling) {
        const float d0 = dist(g_from, c);
        if (d0 > 1) s->scale = std::clamp(g_start.scale * dist(p, c) / d0, 0.1f, 20.0f);
      } else {
        const float a0 = std::atan2(g_from.y - c.y, g_from.x - c.x), a1 = std::atan2(p.y - c.y, p.x - c.x);
        float r = g_start.rot + (a1 - a0) * 180 / kPi;
        if (shift) r = std::round(r / 15) * 15;
        s->rot = r;
      }
      RECT after = areaOf(*s);
      UnionRect(&before, &before, &after);
      render(&before);
      return;
    }
    case kNone:
      return;
  }
}

void onUp() {
  if (g_drag == kDrawing) {
    g_drag = kNone;
    endDrawing();
    return;
  }
  if (g_drag == kMoving || g_drag == kScaling || g_drag == kRotating) {
    // Nothing really moved: no undo step.
    const Mark* s = findMark(g_selected);
    auto& u = sheet().undo;
    if (s && !u.empty() && s->dx == g_start.dx && s->dy == g_start.dy && s->scale == g_start.scale && s->rot == g_start.rot) u.pop_back();
    emitState();
  }
  g_drag = kNone;
}

D2D1_POINT_2F screenPoint(LPARAM lp) {
  // Client coordinates of the layer → screen pixels.
  return D2D1::Point2F(static_cast<float>(static_cast<short>(LOWORD(lp)) + g_virt.left),
                       static_cast<float>(static_cast<short>(HIWORD(lp)) + g_virt.top));
}

LRESULT CALLBACK layerProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_SETCURSOR:
      SetCursor(LoadCursorW(nullptr, g_tool == kSelect ? IDC_ARROW : g_tool == kText ? IDC_IBEAM : IDC_CROSS));
      return TRUE;
    case WM_LBUTTONDOWN:
      SetCapture(h);
      onDown(screenPoint(lp));
      return 0;
    case WM_MOUSEMOVE:
      if (wp & MK_LBUTTON) onMove(screenPoint(lp));
      return 0;
    case WM_LBUTTONUP:
      ReleaseCapture();
      onUp();
      return 0;
    case WM_CAPTURECHANGED:
      if (g_drag != kNone) onUp();
      return 0;
    default:
      return DefWindowProcW(h, msg, wp, lp);
  }
}

// Keys while the pen is on: the toggle key switches draw / operate;
// Delete / Backspace remove what is selected, Esc lets it go (only while
// drawing, so typing in an app is never taken).
LRESULT CALLBACK keyHook(int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION && g_visible) {
    const auto* k = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lp);
    const bool down = wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN;
    const int vk = static_cast<int>(k->vkCode);
    if (g_toggleKey != 0 && vk == g_toggleKey) {
      if (down && !g_keyHeld) {
        g_keyHeld = true;
        setMode(!g_draw);
      } else if (!down) {
        g_keyHeld = false;
      }
      return 1;
    }
    if (down && g_draw && !g_pass && g_selected != 0) {
      if (vk == VK_DELETE || vk == VK_BACK) {
        deleteSelected();
        return 1;
      }
      if (vk == VK_ESCAPE) {
        select(0);
        return 1;
      }
    }
  }
  return CallNextHookEx(nullptr, code, wp, lp);
}

// The wheel over a selected mark: bigger / smaller (Shift: turn 15°).
bool wheelOnSelected(const MSLLHOOKSTRUCT* m) {
  Mark* s = findMark(g_selected);
  const auto p = D2D1::Point2F(static_cast<float>(m->pt.x), static_cast<float>(m->pt.y));
  if (!s || !insideBox(*s, p) || g_drag != kNone) return false;
  const int notches = static_cast<short>(HIWORD(m->mouseData)) / WHEEL_DELTA;
  if (notches == 0) return true;
  // One undo step for a turn of the wheel (not for each notch).
  const ULONGLONG now = GetTickCount64();
  if (now - g_lastWheel > 700) remember();
  g_lastWheel = now;
  RECT before = areaOf(*s);
  if (GetAsyncKeyState(VK_SHIFT) & 0x8000) {
    s->rot = std::round((s->rot + 15.0f * notches) / 15) * 15;
  } else {
    s->scale = std::clamp(s->scale * std::pow(1.1f, static_cast<float>(notches)), 0.1f, 20.0f);
  }
  RECT after = areaOf(*s);
  UnionRect(&before, &before, &after);
  render(&before);
  emitState();
  return true;
}

// A pen (stylus) draws even while the mouse goes through to the apps.
LRESULT CALLBACK mouseHook(int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION && wp == WM_MOUSEWHEEL && g_draw && !g_pass && g_visible && g_selected != 0) {
    if (wheelOnSelected(reinterpret_cast<const MSLLHOOKSTRUCT*>(lp))) return 1;
  }
  if (code == HC_ACTION && g_penDraw && !g_draw && g_visible) {
    const auto* m = reinterpret_cast<const MSLLHOOKSTRUCT*>(lp);
    const bool pen = (m->dwExtraInfo & 0xFFFFFF80) == 0xFF515700;
    if (pen && g_tool != kSelect && g_tool != kEraser && g_tool != kText) {
      const auto p = D2D1::Point2F(static_cast<float>(m->pt.x), static_cast<float>(m->pt.y));
      if (wp == WM_LBUTTONDOWN) {
        g_penDown = true;
        onDown(p);
        return 1;
      }
      if (wp == WM_MOUSEMOVE && g_penDown) {
        onMove(p);
        return 1;
      }
      if (wp == WM_LBUTTONUP && g_penDown) {
        g_penDown = false;
        onUp();
        return 1;
      }
    }
  }
  return CallNextHookEx(nullptr, code, wp, lp);
}

// ---------------------------------------------------------------- pages

bool isShell(HWND w) {
  wchar_t cls[96] = {};
  GetClassNameW(w, cls, 96);
  const std::wstring c = cls;
  return c == L"Shell_TrayWnd" || c == L"Shell_SecondaryTrayWnd" || c == L"Windows.UI.Core.CoreWindow" ||
         c == L"XamlExplorerHostIslandWindow" || c == L"MultitaskingViewFrame" || c == L"TaskSwitcherWnd" ||
         c == L"ForegroundStaging" || c == L"NotifyIconOverflowWindow" || c == L"TopLevelWindowForOverflowXamlIsland";
}

void switchPage(HWND w) {
  if (w == g_page) return;
  if (g_drag != kNone) onUp();
  g_page = w;
  g_selected = 0;
  render();
  emitState();
}

void CALLBACK onForeground(HWINEVENTHOOK, DWORD, HWND w, LONG, LONG, DWORD, DWORD) {
  if (!w) return;
  w = GetAncestor(w, GA_ROOT);
  if (!w || w == g_own || w == g_layer || w == g_spot || w == g_frame || w == g_msg || isShell(w)) return;
  DWORD pid = 0;
  GetWindowThreadProcessId(w, &pid);
  if (pid == GetCurrentProcessId()) return;
  switchPage(w);
}

// ---------------------------------------------------------------- the light around the mouse

void makeSpot() {
  const int d = static_cast<int>(84 * dpiScaleAt(POINT{0, 0}));
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof bi.bmiHeader;
  bi.bmiHeader.biWidth = d;
  bi.bmiHeader.biHeight = -d;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  void* bits = nullptr;
  HBITMAP bmp = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  HGDIOBJ old = SelectObject(dc, bmp);
  auto* px = static_cast<UINT32*>(bits);
  const float r = d / 2.0f;
  for (int y = 0; y < d; ++y) {
    for (int x = 0; x < d; ++x) {
      const float dd = std::sqrt((x + 0.5f - r) * (x + 0.5f - r) + (y + 0.5f - r) * (y + 0.5f - r));
      float a = dd > r ? 0 : (dd > r - 3 ? 0.75f : 0.32f);
      if (dd > r - 1 && dd <= r) a = 0.4f;
      const auto A = static_cast<UINT32>(a * 255);
      // Premultiplied warm yellow.
      px[y * d + x] = (A << 24) | ((255 * A / 255) << 16) | ((214 * A / 255) << 8) | (64 * A / 255);
    }
  }
  POINT src{0, 0}, at{0, 0};
  SIZE size{d, d};
  BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(g_spot, screen, &at, &size, dc, &src, 0, &bf, ULW_ALPHA);
  SelectObject(dc, old);
  DeleteObject(bmp);
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
}

void moveSpot() {
  if (!g_highlight || !g_spot) return;
  POINT p;
  GetCursorPos(&p);
  RECT r;
  GetWindowRect(g_spot, &r);
  const int d = r.right - r.left;
  SetWindowPos(g_spot, HWND_TOPMOST, p.x - d / 2, p.y - d / 2, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

// ---------------------------------------------------------------- red frame around the recorded area

void showFrame(const RECT* area) {
  if (!area) {
    ShowWindow(g_frame, SW_HIDE);
    return;
  }
  const int pad = 6;
  const int w = area->right - area->left + pad * 2, h = area->bottom - area->top + pad * 2;
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof bi.bmiHeader;
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  void* bits = nullptr;
  HBITMAP bmp = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  HGDIOBJ old = SelectObject(dc, bmp);
  auto* px = static_cast<UINT32*>(bits);
  std::fill(px, px + static_cast<size_t>(w) * h, 0u);
  // Dashes 10 on, 6 off, 3 pixels thick, just outside the area.
  auto dot = [&](int x, int y, int along) {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    if (along % 16 < 10) px[y * w + x] = 0xFFFF3B30;
  };
  for (int t = 0; t < 3; ++t) {
    for (int x = 0; x < w; ++x) {
      dot(x, t + 1, x);
      dot(x, h - 2 - t, x);
    }
    for (int y = 0; y < h; ++y) {
      dot(t + 1, y, y);
      dot(w - 2 - t, y, y);
    }
  }
  POINT src{0, 0}, at{area->left - pad, area->top - pad};
  SIZE size{w, h};
  BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(g_frame, screen, &at, &size, dc, &src, 0, &bf, ULW_ALPHA);
  SelectObject(dc, old);
  DeleteObject(bmp);
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
  SetWindowPos(g_frame, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

// ---------------------------------------------------------------- commands

std::wstring wide(const std::string& s) {
  if (s.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

void command(const std::string& line) {
  const auto sp = line.find(' ');
  const std::string cmd = line.substr(0, sp);
  const std::string arg = sp == std::string::npos ? "" : line.substr(sp + 1);
  if (cmd == "quit") {
    PostQuitMessage(0);
  } else if (cmd == "own") {
    g_own = reinterpret_cast<HWND>(static_cast<INT_PTR>(std::strtoll(arg.c_str(), nullptr, 10)));
    HWND fg = GetForegroundWindow();
    if (fg && fg != g_own && !isShell(fg)) g_page = GetAncestor(fg, GA_ROOT);
    render();
    emitState();
  } else if (cmd == "page") {
    switchPage(reinterpret_cast<HWND>(static_cast<INT_PTR>(std::strtoll(arg.c_str(), nullptr, 10))));
  } else if (cmd == "mode") {
    setMode(arg == "draw");
  } else if (cmd == "tool") {
    const std::wstring w = wide(arg);
    for (int i = 0; i <= kEraser; ++i) {
      if (w == kToolNames[i]) g_tool = i;
    }
    if (g_tool != kSelect && g_selected) select(0);
  } else if (cmd == "color") {
    g_color = static_cast<UINT32>(std::strtoul(arg.c_str(), nullptr, 16));
    if (Mark* s = findMark(g_selected)) {
      remember();
      s->argb = g_color;
      render();
      emitState();
    }
  } else if (cmd == "level") {
    g_level = std::clamp(std::atoi(arg.c_str()), 0, 2);
  } else if (cmd == "undo" || cmd == "redo") {
    auto& s = sheet();
    auto& from = cmd == "undo" ? s.undo : s.redo;
    auto& to = cmd == "undo" ? s.redo : s.undo;
    if (!from.empty()) {
      to.push_back(s.marks);
      s.marks = from.back();
      from.pop_back();
      g_selected = 0;
      render();
    }
    emitState();
  } else if (cmd == "clear") {
    if (!sheet().marks.empty()) {
      remember();
      sheet().marks.clear();
      g_selected = 0;
      render();
    }
    emitState();
  } else if (cmd == "delete") {
    deleteSelected();
  } else if (cmd == "newpage") {
    auto& p = page();
    p.sheets.emplace_back();
    p.cur = static_cast<int>(p.sheets.size()) - 1;
    g_selected = 0;
    render();
    emitState();
  } else if (cmd == "prevpage" || cmd == "nextpage") {
    auto& p = page();
    p.cur = std::clamp(p.cur + (cmd == "prevpage" ? -1 : 1), 0, static_cast<int>(p.sheets.size()) - 1);
    g_selected = 0;
    render();
    emitState();
  } else if (cmd == "board") {
    g_board = arg == "white" ? 1 : arg == "black" ? 2 : 0;
    POINT c;
    GetCursorPos(&c);
    MONITORINFO mi{};
    mi.cbSize = sizeof mi;
    GetMonitorInfoW(MonitorFromPoint(c, MONITOR_DEFAULTTONEAREST), &mi);
    g_boardRect = mi.rcMonitor;
    render();
  } else if (cmd == "highlight") {
    g_highlight = arg == "1";
    if (g_highlight) {
      moveSpot();
    } else {
      ShowWindow(g_spot, SW_HIDE);
    }
  } else if (cmd == "fade") {
    g_fade = arg == "1";
  } else if (cmd == "autoreturn") {
    g_autoReturn = arg == "1";
  } else if (cmd == "pendraw") {
    g_penDraw = arg == "1";
  } else if (cmd == "togglekey") {
    g_toggleKey = std::atoi(arg.c_str());
    g_keyHeld = false;
  } else if (cmd == "text") {
    // text <x> <y> <words>
    char* end = nullptr;
    const long x = std::strtol(arg.c_str(), &end, 10);
    const long y = std::strtol(end, &end, 10);
    while (end && *end == ' ') ++end;
    const std::wstring words = wide(end ? std::string(end) : std::string());
    if (!words.empty()) {
      remember();
      Mark m = newMark(kText, D2D1::Point2F(static_cast<float>(x), static_cast<float>(y)));
      m.text = words;
      m.doneAt = GetTickCount64();
      sheet().marks.push_back(m);
      render();
      emitState();
    }
  } else if (cmd == "border") {
    if (arg == "off") {
      showFrame(nullptr);
    } else {
      long v[4] = {};
      char* p = const_cast<char*>(arg.c_str());
      for (auto& x : v) x = std::strtol(p, &p, 10);
      RECT r{v[0], v[1], v[0] + v[2], v[1] + v[3]};
      showFrame(&r);
    }
  } else if (cmd == "probe") {
    // probe <x> <y>: the layer's pixel there (checks drawing works).
    char* p = const_cast<char*>(arg.c_str());
    const long x = std::strtol(p, &p, 10) - g_virt.left, y = std::strtol(p, &p, 10) - g_virt.top;
    const long w = g_virt.right - g_virt.left, h = g_virt.bottom - g_virt.top;
    GdiFlush();
    char b[64];
    std::snprintf(b, sizeof b, "pixel %08X", x >= 0 && y >= 0 && x < w && y < h && g_bits ? g_bits[y * w + x] : 0u);
    emit(b);
  } else if (cmd == "visible") {
    g_visible = arg == "1";
    render();
  }
}

LRESULT CALLBACK msgProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == kCmd) {
    auto* s = reinterpret_cast<std::string*>(lp);
    command(*s);
    delete s;
    return 0;
  }
  if (msg == kQuit) {
    PostQuitMessage(0);
    return 0;
  }
  if (msg == WM_TIMER && wp == kTimerCursor) {
    moveSpot();
    return 0;
  }
  if (msg == WM_TIMER && wp == kTimerTick) {
    // Hold Ctrl while drawing: the mouse goes through for that moment.
    if (g_draw && g_drag == kNone) {
      const bool ctrl = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
      if (ctrl != g_pass) {
        g_pass = ctrl;
        setPassThrough();
        render();
      }
    }
    // Fading marks.
    const ULONGLONG now = GetTickCount64();
    bool any = false, gone = false;
    for (auto& [w, p] : g_pages) {
      for (auto& s : p.sheets) {
        auto& ms = s.marks;
        for (const auto& m : ms) {
          if (m.fades && m.doneAt && now - m.doneAt > 3000) any = true;
        }
        const auto before = ms.size();
        ms.erase(std::remove_if(ms.begin(), ms.end(), [now](const Mark& m) { return m.fades && m.doneAt && now - m.doneAt > 3500; }),
                 ms.end());
        if (ms.size() != before) gone = true;
      }
    }
    if (any || gone) render();
    if (gone) emitState();
    return 0;
  }
  return DefWindowProcW(h, msg, wp, lp);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
  g_inst = inst;
  // Real pixels on every screen (matches LocalRoll's window places).
  using SetCtx = BOOL(WINAPI*)(HANDLE);
  auto setCtx = reinterpret_cast<SetCtx>(reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetProcessDpiAwarenessContext")));
  if (!setCtx || !setCtx(reinterpret_cast<HANDLE>(static_cast<INT_PTR>(-4)))) SetProcessDPIAware();

  if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, g_d2d.put())) ||
      FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(g_dw.put())))) {
    emit("error no Direct2D");
    return 1;
  }

  g_virt = RECT{GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN), 0, 0};
  g_virt.right = g_virt.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
  g_virt.bottom = g_virt.top + GetSystemMetrics(SM_CYVIRTUALSCREEN);
  const int w = g_virt.right - g_virt.left, h = g_virt.bottom - g_virt.top;

  WNDCLASSEXW wc{};
  wc.cbSize = sizeof wc;
  wc.hInstance = inst;
  wc.lpfnWndProc = msgProc;
  wc.lpszClassName = L"LocalRollPenMsg";
  RegisterClassExW(&wc);
  g_msg = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, inst, nullptr);

  wc.lpfnWndProc = layerProc;
  wc.lpszClassName = L"LocalRollPenLayer";
  wc.hCursor = LoadCursorW(nullptr, IDC_CROSS);
  RegisterClassExW(&wc);
  g_layer = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT, wc.lpszClassName,
                            L"LocalRoll pen", WS_POPUP, g_virt.left, g_virt.top, w, h, nullptr, nullptr, inst, nullptr);

  wc.lpfnWndProc = DefWindowProcW;
  wc.lpszClassName = L"LocalRollPenSpot";
  RegisterClassExW(&wc);
  g_spot = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT, wc.lpszClassName,
                           L"", WS_POPUP, 0, 0, 10, 10, nullptr, nullptr, inst, nullptr);
  g_frame = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT, wc.lpszClassName,
                            L"", WS_POPUP, 0, 0, 10, 10, nullptr, nullptr, inst, nullptr);
  if (!g_layer || !g_spot || !g_frame || !g_msg) {
    emit("error no window");
    return 1;
  }
  // The frame is for the person only, never in a recording.
  SetWindowDisplayAffinity(g_frame, WDA_EXCLUDEFROMCAPTURE);
  makeSpot();

  // The layer's pixels.
  HDC screen = GetDC(nullptr);
  g_dc = CreateCompatibleDC(screen);
  ReleaseDC(nullptr, screen);
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof bi.bmiHeader;
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  void* bits = nullptr;
  g_dib = CreateDIBSection(g_dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!g_dib) {
    emit("error no memory");
    return 1;
  }
  g_bits = static_cast<UINT32*>(bits);
  g_oldBmp = SelectObject(g_dc, g_dib);
  D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
  if (FAILED(g_d2d->CreateDCRenderTarget(&props, g_rt.put()))) {
    emit("error no render target");
    return 1;
  }
  render();
  ShowWindow(g_layer, SW_SHOWNOACTIVATE);

  g_hook = SetWindowsHookExW(WH_MOUSE_LL, mouseHook, inst, 0);
  g_keys = SetWindowsHookExW(WH_KEYBOARD_LL, keyHook, inst, 0);
  g_fgHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, onForeground, 0, 0,
                             WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
  SetTimer(g_msg, kTimerTick, 40, nullptr);
  SetTimer(g_msg, kTimerCursor, 15, nullptr);

  char b[96];
  std::snprintf(b, sizeof b, "ready %ld %ld %d %d", g_virt.left, g_virt.top, w, h);
  emit(b);

  // Commands from LocalRoll, one per line; end of input ends the pen.
  std::thread([] {
    std::string line;
    while (std::getline(std::cin, line)) {
      while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
      PostMessageW(g_msg, kCmd, 0, reinterpret_cast<LPARAM>(new std::string(line)));
    }
    PostMessageW(g_msg, kQuit, 0, 0);
  }).detach();

  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  if (g_hook) UnhookWindowsHookEx(g_hook);
  if (g_keys) UnhookWindowsHookEx(g_keys);
  if (g_fgHook) UnhookWinEvent(g_fgHook);
  g_rt.reset();
  SelectObject(g_dc, g_oldBmp);
  DeleteObject(g_dib);
  DeleteDC(g_dc);
  DestroyWindow(g_layer);
  DestroyWindow(g_spot);
  DestroyWindow(g_frame);
  std::_Exit(0);
}
