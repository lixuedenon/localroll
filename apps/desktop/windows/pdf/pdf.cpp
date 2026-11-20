// apps/desktop/windows/pdf/pdf.cpp
//
// LocalRoll's PDF builder. Reads a plan (UTF-8 text file), writes one PDF:
//
//   OUT <path>
//   DOC <path>                                   a PDF to take pages from
//   PAGE <doc>|<page>|<turn>                     page (0-based) of DOC no. <doc>,
//                                                turned <turn> × 90° clockwise
//   STAMP <bgra>|<pxw>|<pxh>|<x>|<y>|<w>|<h>     a picture (raw BGRA, with see-
//                                                through parts) on the last PAGE;
//                                                x y w h: 0–1 of the page as shown
//   IMAGE <jpg>|<pw>|<ph>|<x>|<y>|<w>|<h>        a new page <pw>×<ph> points with
//                                                the photo at x y w h (points,
//                                                from the bottom left)
//   EDIT <l>|<b>|<r>|<t>|<x>|<base>|<size>|<rgb>|<font>|<text>
//                                                on the last PAGE: the text in the
//                                                box l b r t (PDF points, the page's
//                                                own space) is taken out and <text>
//                                                (a UTF-8 file) written at x, <base>
//                                                (baseline), <size> points, colour
//                                                <rgb> (hex, or "auto": the old
//                                                text's), font file <font> (.ttf,
//                                                embedded). A box whose text runs on
//                                                outside it is left alone (counted
//                                                as skipped: changing it would move
//                                                the text beside it).
//
//   MARKS <file>                                 on the last PAGE: Keepnear's own marks
//                                                (base64 text) kept in a hidden annotation,
//                                                so they can be changed again later
//   NOTE <x>|<y>|<text>|<rgb>                    on the last PAGE: a note (a PDF text
//                                                annotation: its icon at x y, 0–1 of
//                                                the page as shown; <text> a UTF-8
//                                                file; readers show it on a click)
//
//   lr_pdf.exe "<plan file>"
//   lr_pdf.exe --print "<pdf>" "<printer>" <copies> <pages> <landscape> <fit> <gray> <duplex>
//              <pages>: 0-based, comma separated; the rest 0 / 1. Prints: ok <n>
// Prints: ok <pages> [skipped <n>]   or   error <why>
//
//   lr_pdf.exe --thumb "<pdf>" "<out.bmp>" <width>
//   lr_pdf.exe --clean "<pdf>" "<out.pdf>"   Keepnear's marks taken off (the picture
//                                            tagged KeepnearMarks, its notes, the
//                                            hidden data): prints "marks <page> <data>"
//                                            per page and "ok", or "none"
//   lr_pdf.exe --notes "<pdf>"     every note (PDF text annotation): prints
//                                  "note <page> <x> <y> <own> <text>" (x, y 0–1 of
//                                  the page as shown; new lines as U+2028)
//   lr_pdf.exe --styles "<pdf>" <page> "<out.txt>"   (the page's text objects,
//              one per line: l|b|r|t|size|weight|italic|rgb|font#|embedded|name|text
//              — size in points as drawn, text as base64 UTF-8)
// The first page as a picture <width> pixels wide (white behind it), for
// the library's previews; in its own process, so a PDF that hangs can't hold
// up the app. Prints: ok   or   error <why>
//
// pdfium.dll (shipped for the PDF viewer) is loaded from the exe's folder;
// the text of pages taken from PDFs stays text (a signature is laid on top).

#include <windows.h>
#include <shellapi.h>
#include <winspool.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "subset.h"

namespace {

typedef void* DOC;
typedef void* PAGE;
typedef void* OBJ;
typedef void* BMP;
typedef void* FONT;
typedef void* TEXTPAGE;
struct Matrix {
  float a, b, c, d, e, f;
};

struct FileAccess {
  unsigned long len;
  int (*getBlock)(void* param, unsigned long pos, unsigned char* buf, unsigned long size);
  void* param;
};

struct FileWrite {
  int version;
  int (*writeBlock)(FileWrite* self, const void* data, unsigned long size);
};

struct Writer : FileWrite {
  FILE* f;
};

struct Api {
  void (*InitLibrary)();
  DOC (*LoadMemDocument)(const void*, int, const char*);
  DOC (*CreateNewDocument)();
  int (*ImportPages)(DOC, DOC, const char*, int);
  int (*GetPageCount)(DOC);
  PAGE (*LoadPage)(DOC, int);
  void (*ClosePage)(PAGE);
  double (*GetPageWidth)(PAGE);
  double (*GetPageHeight)(PAGE);
  int (*GetRotation)(PAGE);
  void (*SetRotation)(PAGE, int);
  int (*GetCropBox)(PAGE, float*, float*, float*, float*);
  int (*GetMediaBox)(PAGE, float*, float*, float*, float*);
  OBJ (*NewImageObj)(DOC);
  int (*LoadJpegFileInline)(PAGE*, int, OBJ, FileAccess*);
  int (*SetBitmap)(PAGE*, int, OBJ, BMP);
  int (*SetMatrix)(OBJ, double, double, double, double, double, double);
  void (*InsertObject)(PAGE, OBJ);
  int (*GenerateContent)(PAGE);
  PAGE (*NewPage)(DOC, int, double, double);
  int (*SaveAsCopy)(DOC, FileWrite*, unsigned long);
  void (*CloseDocument)(DOC);
  BMP (*BitmapCreateEx)(int, int, int, void*, int);
  void (*BitmapDestroy)(BMP);
  // For EDIT (optional: without them EDIT is skipped).
  int (*CountObjects)(PAGE);
  OBJ (*GetObject)(PAGE, int);
  int (*ObjGetType)(OBJ);
  int (*ObjGetBounds)(OBJ, float*, float*, float*, float*);
  int (*RemoveObject)(PAGE, OBJ);
  void (*ObjDestroy)(OBJ);
  int (*ObjGetFillColor)(OBJ, unsigned int*, unsigned int*, unsigned int*, unsigned int*);
  FONT (*LoadFont)(DOC, const unsigned char*, unsigned int, int, int);
  OBJ (*CreateTextObj)(DOC, FONT, float);
  int (*TextSetText)(OBJ, const unsigned short*);
  int (*ObjSetFillColor)(OBJ, unsigned int, unsigned int, unsigned int, unsigned int);
  void (*ObjTransform)(OBJ, double, double, double, double, double, double);
  void (*FontClose)(FONT);
  // Reading a text's style (--styles), and keeping it (EDIT).
  FONT (*TextObjGetFont)(OBJ);
  int (*TextObjGetFontSize)(OBJ, float*);
  int (*ObjGetMatrix)(OBJ, Matrix*);
  unsigned long (*FontGetBaseName)(FONT, char*, unsigned long);
  unsigned long (*FontGetFamilyName)(FONT, char*, unsigned long);
  int (*FontGetWeight)(FONT);
  int (*FontGetItalicAngle)(FONT, int*);
  int (*FontGetIsEmbedded)(FONT);
  TEXTPAGE (*TextLoadPage)(PAGE);
  void (*TextClosePage)(TEXTPAGE);
  unsigned long (*TextObjGetText)(OBJ, TEXTPAGE, unsigned short*, unsigned long);
  int (*TextObjSetRenderMode)(OBJ, int);
  int (*ObjSetStrokeColor)(OBJ, unsigned int, unsigned int, unsigned int, unsigned int);
  int (*ObjSetStrokeWidth)(OBJ, float);
  // Notes (NOTE).
  void* (*CreateAnnot)(PAGE, int);
  int (*AnnotSetRect)(void*, const float*);
  int (*AnnotSetString)(void*, const char*, const unsigned short*);
  int (*AnnotSetColor)(void*, int, unsigned int, unsigned int, unsigned int, unsigned int);
  void (*CloseAnnot)(void*);
  // Keepnear's marks: tagged, kept, taken off again (MARKS, --clean, --notes).
  void* (*AddMark)(OBJ, const char*);
  int (*CountMarks)(OBJ);
  void* (*GetMark)(OBJ, unsigned long);
  int (*MarkGetName)(void*, void*, unsigned long, unsigned long*);
  int (*AnnotCount)(PAGE);
  void* (*GetAnnot)(PAGE, int);
  int (*RemoveAnnot)(PAGE, int);
  int (*AnnotHasKey)(void*, const char*);
  unsigned long (*AnnotGetString)(void*, const char*, unsigned short*, unsigned long);
  int (*AnnotGetSubtype)(void*);
  int (*AnnotGetRect)(void*, float*);
  int (*AnnotSetFlags)(void*, int);
  // Printing (--print): straight to the printer, or through a picture.
  void (*RenderPage)(HDC, PAGE, int, int, int, int, int, int);
  // For --thumb only.
  void (*RenderPageBitmap)(BMP, PAGE, int, int, int, int, int, int);
  int (*FillRect)(BMP, int, int, int, int, unsigned long);
};

Api api{};

void say(const std::string& s) {
  HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
  std::string line = s + "\n";
  DWORD n = 0;
  if (h && h != INVALID_HANDLE_VALUE) WriteFile(h, line.data(), (DWORD)line.size(), &n, nullptr);
}

std::wstring wide(const std::string& s) {
  if (s.empty()) return L"";
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
  return w;
}

bool readAll(const std::string& path, std::vector<unsigned char>& out) {
  FILE* f = _wfopen(wide(path).c_str(), L"rb");
  if (!f) return false;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (n < 0) {
    fclose(f);
    return false;
  }
  out.resize((size_t)n);
  bool ok = n == 0 || fread(out.data(), 1, (size_t)n, f) == (size_t)n;
  fclose(f);
  return ok;
}

std::vector<std::string> split(const std::string& s, char c) {
  std::vector<std::string> v;
  size_t a = 0;
  for (;;) {
    size_t b = s.find(c, a);
    v.push_back(s.substr(a, b == std::string::npos ? std::string::npos : b - a));
    if (b == std::string::npos) break;
    a = b + 1;
  }
  return v;
}

template <typename T>
bool find(HMODULE m, const char* name, T& fn) {
  fn = reinterpret_cast<T>(GetProcAddress(m, name));
  return fn != nullptr;
}

bool load() {
  wchar_t exe[MAX_PATH];
  GetModuleFileNameW(nullptr, exe, MAX_PATH);
  std::wstring dir(exe);
  dir = dir.substr(0, dir.find_last_of(L"\\/") + 1);
  HMODULE m = LoadLibraryW((dir + L"pdfium.dll").c_str());
  if (!m) m = LoadLibraryW(L"pdfium.dll");
  if (!m) return false;
  bool ok = find(m, "FPDF_InitLibrary", api.InitLibrary) && find(m, "FPDF_LoadMemDocument", api.LoadMemDocument) &&
            find(m, "FPDF_CreateNewDocument", api.CreateNewDocument) && find(m, "FPDF_ImportPages", api.ImportPages) &&
            find(m, "FPDF_GetPageCount", api.GetPageCount) && find(m, "FPDF_LoadPage", api.LoadPage) &&
            find(m, "FPDF_ClosePage", api.ClosePage) && find(m, "FPDF_GetPageWidth", api.GetPageWidth) &&
            find(m, "FPDF_GetPageHeight", api.GetPageHeight) && find(m, "FPDFPage_GetRotation", api.GetRotation) &&
            find(m, "FPDFPage_SetRotation", api.SetRotation) && find(m, "FPDFPageObj_NewImageObj", api.NewImageObj) &&
            find(m, "FPDFImageObj_LoadJpegFileInline", api.LoadJpegFileInline) &&
            find(m, "FPDFImageObj_SetBitmap", api.SetBitmap) && find(m, "FPDFImageObj_SetMatrix", api.SetMatrix) &&
            find(m, "FPDFPage_InsertObject", api.InsertObject) && find(m, "FPDFPage_GenerateContent", api.GenerateContent) &&
            find(m, "FPDFPage_New", api.NewPage) && find(m, "FPDF_SaveAsCopy", api.SaveAsCopy) &&
            find(m, "FPDF_CloseDocument", api.CloseDocument) && find(m, "FPDFBitmap_CreateEx", api.BitmapCreateEx) &&
            find(m, "FPDFBitmap_Destroy", api.BitmapDestroy);
  find(m, "FPDF_RenderPageBitmap", api.RenderPageBitmap);
  find(m, "FPDFPage_CreateAnnot", api.CreateAnnot);
  find(m, "FPDFAnnot_SetRect", api.AnnotSetRect);
  find(m, "FPDFAnnot_SetStringValue", api.AnnotSetString);
  find(m, "FPDFAnnot_SetColor", api.AnnotSetColor);
  find(m, "FPDFPage_CloseAnnot", api.CloseAnnot);
  find(m, "FPDFPageObj_AddMark", api.AddMark);
  find(m, "FPDFPageObj_CountMarks", api.CountMarks);
  find(m, "FPDFPageObj_GetMark", api.GetMark);
  find(m, "FPDFPageObjMark_GetName", api.MarkGetName);
  find(m, "FPDFPage_GetAnnotCount", api.AnnotCount);
  find(m, "FPDFPage_GetAnnot", api.GetAnnot);
  find(m, "FPDFPage_RemoveAnnot", api.RemoveAnnot);
  find(m, "FPDFAnnot_HasKey", api.AnnotHasKey);
  find(m, "FPDFAnnot_GetStringValue", api.AnnotGetString);
  find(m, "FPDFAnnot_GetSubtype", api.AnnotGetSubtype);
  find(m, "FPDFAnnot_GetRect", api.AnnotGetRect);
  find(m, "FPDFAnnot_SetFlags", api.AnnotSetFlags);
  find(m, "FPDF_RenderPage", api.RenderPage);
  find(m, "FPDFBitmap_FillRect", api.FillRect);
  // Optional: changing text (EDIT).
  find(m, "FPDFPage_CountObjects", api.CountObjects);
  find(m, "FPDFPage_GetObject", api.GetObject);
  find(m, "FPDFPageObj_GetType", api.ObjGetType);
  find(m, "FPDFPageObj_GetBounds", api.ObjGetBounds);
  find(m, "FPDFPage_RemoveObject", api.RemoveObject);
  find(m, "FPDFPageObj_Destroy", api.ObjDestroy);
  find(m, "FPDFPageObj_GetFillColor", api.ObjGetFillColor);
  find(m, "FPDFText_LoadFont", api.LoadFont);
  find(m, "FPDFPageObj_CreateTextObj", api.CreateTextObj);
  find(m, "FPDFText_SetText", api.TextSetText);
  find(m, "FPDFPageObj_SetFillColor", api.ObjSetFillColor);
  find(m, "FPDFPageObj_Transform", api.ObjTransform);
  find(m, "FPDFFont_Close", api.FontClose);
  find(m, "FPDFTextObj_GetFont", api.TextObjGetFont);
  find(m, "FPDFTextObj_GetFontSize", api.TextObjGetFontSize);
  find(m, "FPDFPageObj_GetMatrix", api.ObjGetMatrix);
  if (!find(m, "FPDFFont_GetBaseFontName", api.FontGetBaseName)) find(m, "FPDFFont_GetFontName", api.FontGetBaseName);
  find(m, "FPDFFont_GetFamilyName", api.FontGetFamilyName);
  find(m, "FPDFFont_GetWeight", api.FontGetWeight);
  find(m, "FPDFFont_GetItalicAngle", api.FontGetItalicAngle);
  find(m, "FPDFFont_GetIsEmbedded", api.FontGetIsEmbedded);
  find(m, "FPDFText_LoadPage", api.TextLoadPage);
  find(m, "FPDFText_ClosePage", api.TextClosePage);
  find(m, "FPDFTextObj_GetText", api.TextObjGetText);
  find(m, "FPDFTextObj_SetTextRenderMode", api.TextObjSetRenderMode);
  find(m, "FPDFPageObj_SetStrokeColor", api.ObjSetStrokeColor);
  find(m, "FPDFPageObj_SetStrokeWidth", api.ObjSetStrokeWidth);
  // Optional (the page box's corner; 0,0 without them).
  find(m, "FPDFPage_GetCropBox", api.GetCropBox);
  find(m, "FPDFPage_GetMediaBox", api.GetMediaBox);
  return ok;
}

int getBlock(void* param, unsigned long pos, unsigned char* buf, unsigned long size) {
  auto* v = static_cast<std::vector<unsigned char>*>(param);
  if ((size_t)pos + size > v->size()) return 0;
  memcpy(buf, v->data() + pos, size);
  return 1;
}

int writeBlock(FileWrite* self, const void* data, unsigned long size) {
  auto* w = static_cast<Writer*>(self);
  return fwrite(data, 1, size, w->f) == size ? 1 : 0;
}

// A point on the page as shown (points, from the top left) → the page's own
// space (from the bottom left, before turning).
void toPage(int rot, double W, double H, double X, double Y, double& ux, double& uy) {
  switch (rot & 3) {
    case 1: ux = Y; uy = X; break;
    case 2: ux = W - X; uy = Y; break;
    case 3: ux = W - Y; uy = H - X; break;
    default: ux = X; uy = H - Y; break;
  }
}

std::string narrow(const wchar_t* w) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (n <= 1) return "";
  std::string s(n - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
  return s;
}

// --thumb: the first page, <width> wide, as a 24-bit BMP.
int thumb(const std::string& pdf, const std::string& outPath, int width) {
  if (!load() || !api.RenderPageBitmap || !api.FillRect) {
    say("error pdfium.dll not usable");
    return 3;
  }
  api.InitLibrary();
  std::vector<unsigned char> bytes;
  if (!readAll(pdf, bytes) || bytes.empty()) {
    say("error cannot read");
    return 1;
  }
  DOC doc = api.LoadMemDocument(bytes.data(), (int)bytes.size(), nullptr);
  if (!doc) {
    say("error cannot open (password or damaged)");
    return 1;
  }
  PAGE page = api.GetPageCount(doc) > 0 ? api.LoadPage(doc, 0) : nullptr;
  if (!page) {
    api.CloseDocument(doc);
    say("error no pages");
    return 1;
  }
  double pw = api.GetPageWidth(page), ph = api.GetPageHeight(page);
  if (width < 16) width = 240;
  int height = pw > 0 ? (int)std::lround(width * ph / pw) : width;
  if (height < 40) height = 40;
  if (height > width * 2) height = width * 2;
  std::vector<unsigned char> px((size_t)width * height * 4);
  BMP bmp = api.BitmapCreateEx(width, height, 4 /* BGRA */, px.data(), width * 4);
  if (!bmp) {
    api.ClosePage(page);
    api.CloseDocument(doc);
    say("error no bitmap");
    return 1;
  }
  api.FillRect(bmp, 0, 0, width, height, 0xFFFFFFFF);
  api.RenderPageBitmap(bmp, page, 0, 0, width, height, 0, 0x01 /* FPDF_ANNOT */);
  api.BitmapDestroy(bmp);
  api.ClosePage(page);
  api.CloseDocument(doc);
  // 24-bit BMP, rows bottom up, each padded to 4 bytes.
  int row = (width * 3 + 3) & ~3;
  unsigned int dataSize = (unsigned int)row * height;
  unsigned char head[54] = {0};
  head[0] = 'B';
  head[1] = 'M';
  auto put32 = [&](int at, unsigned int v) {
    head[at] = v & 255;
    head[at + 1] = (v >> 8) & 255;
    head[at + 2] = (v >> 16) & 255;
    head[at + 3] = (v >> 24) & 255;
  };
  put32(2, 54 + dataSize);
  put32(10, 54);
  put32(14, 40);
  put32(18, (unsigned int)width);
  put32(22, (unsigned int)height);
  head[26] = 1;
  head[28] = 24;
  put32(34, dataSize);
  FILE* f = _wfopen(wide(outPath).c_str(), L"wb");
  if (!f) {
    say("error cannot write");
    return 1;
  }
  fwrite(head, 1, 54, f);
  std::vector<unsigned char> line((size_t)row, 0);
  for (int y = height - 1; y >= 0; y--) {
    const unsigned char* src = px.data() + (size_t)y * width * 4;
    for (int x = 0; x < width; x++) {
      line[x * 3] = src[x * 4];
      line[x * 3 + 1] = src[x * 4 + 1];
      line[x * 3 + 2] = src[x * 4 + 2];
    }
    fwrite(line.data(), 1, (size_t)row, f);
  }
  bool ok = ferror(f) == 0;
  fclose(f);
  if (!ok) {
    say("error cannot write");
    return 1;
  }
  say("ok");
  return 0;
}

std::string b64(const std::string& in) {
  static const char* t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  size_t i = 0;
  for (; i + 2 < in.size(); i += 3) {
    unsigned v = ((unsigned char)in[i] << 16) | ((unsigned char)in[i + 1] << 8) | (unsigned char)in[i + 2];
    out += t[v >> 18];
    out += t[(v >> 12) & 63];
    out += t[(v >> 6) & 63];
    out += t[v & 63];
  }
  if (i + 1 == in.size()) {
    unsigned v = (unsigned char)in[i] << 16;
    out += t[v >> 18];
    out += t[(v >> 12) & 63];
    out += "==";
  } else if (i + 2 == in.size()) {
    unsigned v = ((unsigned char)in[i] << 16) | ((unsigned char)in[i + 1] << 8);
    out += t[v >> 18];
    out += t[(v >> 12) & 63];
    out += t[(v >> 6) & 63];
    out += '=';
  }
  return out;
}

// The size a text object is drawn at: its font size times the matrix's
// vertical scale.
double drawnSize(OBJ o) {
  float fs = 0;
  if (!api.TextObjGetFontSize || !api.TextObjGetFontSize(o, &fs)) return 0;
  Matrix m{1, 0, 0, 1, 0, 0};
  if (api.ObjGetMatrix) api.ObjGetMatrix(o, &m);
  double sy = sqrt((double)m.c * m.c + (double)m.d * m.d);
  return fs * (sy > 0 ? sy : 1);
}

// --styles: each text object of one page, with how it looks.
int styles(const std::string& pdf, int index, const std::wstring& outPath) {
  if (!load() || !api.CountObjects || !api.GetObject || !api.ObjGetType || !api.ObjGetBounds || !api.TextObjGetFont) {
    say("error pdfium.dll not usable");
    return 3;
  }
  api.InitLibrary();
  std::vector<unsigned char> bytes;
  if (!readAll(pdf, bytes) || bytes.empty()) {
    say("error cannot read");
    return 1;
  }
  DOC doc = api.LoadMemDocument(bytes.data(), (int)bytes.size(), nullptr);
  if (!doc) {
    say("error cannot open (password or damaged)");
    return 1;
  }
  PAGE page = index >= 0 && index < api.GetPageCount(doc) ? api.LoadPage(doc, index) : nullptr;
  if (!page) {
    api.CloseDocument(doc);
    say("error no page");
    return 1;
  }
  TEXTPAGE tp = api.TextLoadPage ? api.TextLoadPage(page) : nullptr;
  std::vector<FONT> fonts;
  std::string out;
  int n = api.CountObjects(page);
  for (int i = 0; i < n; i++) {
    OBJ o = api.GetObject(page, i);
    if (!o || api.ObjGetType(o) != 1) continue;
    float l = 0, b = 0, r = 0, t = 0;
    if (!api.ObjGetBounds(o, &l, &b, &r, &t)) continue;
    FONT f = api.TextObjGetFont(o);
    int fi = -1;
    for (size_t k = 0; k < fonts.size(); k++) {
      if (fonts[k] == f) fi = (int)k;
    }
    if (fi < 0) {
      fonts.push_back(f);
      fi = (int)fonts.size() - 1;
    }
    std::string name;
    if (f && api.FontGetBaseName) {
      char buf[256] = {0};
      unsigned long len = api.FontGetBaseName(f, buf, sizeof buf);
      if (len > 0 && len <= sizeof buf) name = buf;
    }
    if (name.empty() && f && api.FontGetFamilyName) {
      char buf[256] = {0};
      unsigned long len = api.FontGetFamilyName(f, buf, sizeof buf);
      if (len > 0 && len <= sizeof buf) name = buf;
    }
    for (char& c : name) {
      if (c == '|' || c == '\n' || c == '\r') c = ' ';
    }
    int weight = f && api.FontGetWeight ? api.FontGetWeight(f) : -1;
    int angle = 0;
    if (f && api.FontGetItalicAngle) api.FontGetItalicAngle(f, &angle);
    Matrix m{1, 0, 0, 1, 0, 0};
    if (api.ObjGetMatrix) api.ObjGetMatrix(o, &m);
    bool italic = angle != 0 || (m.d != 0 && fabs(m.c / m.d) > 0.12);
    int embedded = f && api.FontGetIsEmbedded ? api.FontGetIsEmbedded(f) : 1;
    unsigned int cr = 0, cg = 0, cb = 0, ca = 255;
    if (api.ObjGetFillColor) api.ObjGetFillColor(o, &cr, &cg, &cb, &ca);
    std::string text;
    if (tp && api.TextObjGetText) {
      unsigned long len = api.TextObjGetText(o, tp, nullptr, 0);
      if (len > 2 && len < 100000) {
        std::vector<unsigned short> w(len / 2 + 1, 0);
        api.TextObjGetText(o, tp, w.data(), len);
        std::wstring ws(w.begin(), w.end());
        ws = ws.c_str();
        int need = WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1, nullptr, 0, nullptr, nullptr);
        if (need > 1) {
          std::string u(need - 1, '\0');
          WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1, &u[0], need, nullptr, nullptr);
          text = u;
        }
      }
    }
    char line[512];
    snprintf(line, sizeof line, "%.2f|%.2f|%.2f|%.2f|%.2f|%d|%d|%02x%02x%02x|%d|%d|", l, b, r, t, drawnSize(o), weight, italic ? 1 : 0, cr, cg, cb, fi,
             embedded);
    out += line;
    out += name + "|" + b64(text) + "\n";
  }
  if (tp) api.TextClosePage(tp);
  api.ClosePage(page);
  api.CloseDocument(doc);
  FILE* f = _wfopen(outPath.c_str(), L"wb");
  if (!f) {
    say("error cannot write");
    return 1;
  }
  fwrite(out.data(), 1, out.size(), f);
  fclose(f);
  say("ok");
  return 0;
}

// --print: each page asked for, fitted to the paper (or at its own size),
// centred. Settings go to the printer's own; Windows' print queue does the
// rest.
int printPdf(const std::string& path, const std::wstring& printer, int copies, const std::string& pagesCsv, bool landscape, bool fit,
             bool gray, bool duplex) {
  if (!load()) {
    say("error pdfium.dll not usable");
    return 3;
  }
  api.InitLibrary();
  std::vector<unsigned char> bytes;
  if (!readAll(path, bytes)) {
    say("error cannot read");
    return 2;
  }
  DOC doc = api.LoadMemDocument(bytes.data(), (int)bytes.size(), nullptr);
  if (!doc) {
    say("error cannot open");
    return 2;
  }
  HANDLE hp = nullptr;
  std::wstring name = printer;
  if (!OpenPrinterW(&name[0], &hp, nullptr)) {
    say("error no printer");
    return 4;
  }
  LONG need = DocumentPropertiesW(nullptr, hp, &name[0], nullptr, nullptr, 0);
  std::vector<BYTE> dmBuf(need > (LONG)sizeof(DEVMODEW) ? (size_t)need : sizeof(DEVMODEW));
  auto* dm = reinterpret_cast<DEVMODEW*>(dmBuf.data());
  DocumentPropertiesW(nullptr, hp, &name[0], dm, nullptr, DM_OUT_BUFFER);
  dm->dmFields |= DM_ORIENTATION | DM_COPIES | DM_COLOR;
  dm->dmOrientation = landscape ? DMORIENT_LANDSCAPE : DMORIENT_PORTRAIT;
  dm->dmCopies = (short)(copies < 1 ? 1 : copies);
  dm->dmColor = gray ? DMCOLOR_MONOCHROME : DMCOLOR_COLOR;
  if (duplex) {
    dm->dmFields |= DM_DUPLEX;
    dm->dmDuplex = landscape ? DMDUP_HORIZONTAL : DMDUP_VERTICAL;
  }
  DocumentPropertiesW(nullptr, hp, &name[0], dm, dm, DM_IN_BUFFER | DM_OUT_BUFFER);
  ClosePrinter(hp);
  HDC dc = CreateDCW(L"WINSPOOL", printer.c_str(), nullptr, dm);
  if (!dc) {
    say("error printer not ready");
    return 4;
  }
  DOCINFOW di{};
  di.cbSize = sizeof di;
  di.lpszDocName = L"Keepnear";
  if (StartDocW(dc, &di) <= 0) {
    DeleteDC(dc);
    say("error printer refused");
    return 4;
  }
  const int pw = GetDeviceCaps(dc, HORZRES), ph = GetDeviceCaps(dc, VERTRES);
  const int dpx = GetDeviceCaps(dc, LOGPIXELSX), dpy = GetDeviceCaps(dc, LOGPIXELSY);
  int printed = 0;
  for (auto& one : split(pagesCsv, ',')) {
    if (one.empty()) continue;
    const int idx = atoi(one.c_str());
    if (idx < 0 || idx >= api.GetPageCount(doc)) continue;
    PAGE p = api.LoadPage(doc, idx);
    if (!p) continue;
    const double w = api.GetPageWidth(p), h = api.GetPageHeight(p);
    int rw, rh;
    if (fit) {
      const double k = std::fmin(pw / w, ph / h);
      rw = (int)(w * k);
      rh = (int)(h * k);
    } else {
      rw = (int)(w * dpx / 72.0);
      rh = (int)(h * dpy / 72.0);
    }
    const int x = (pw - rw) / 2, y = (ph - rh) / 2;
    StartPage(dc);
    if (api.RenderPage) {
      api.RenderPage(dc, p, x, y, rw, rh, 0, 0x01 /* annotations */ | 0x800 /* printing */ | (gray ? 0x08 : 0));
    } else if (api.RenderPageBitmap && api.FillRect) {
      // Through a picture, at most 300 dpi.
      const double k = std::fmin(1.0, 300.0 / (dpx > 0 ? dpx : 300));
      const int bw = (int)(rw * k), bh = (int)(rh * k);
      std::vector<unsigned char> px((size_t)bw * bh * 4);
      BMP bmp = api.BitmapCreateEx(bw, bh, 4, px.data(), bw * 4);
      if (bmp) {
        api.FillRect(bmp, 0, 0, bw, bh, 0xFFFFFFFF);
        api.RenderPageBitmap(bmp, p, 0, 0, bw, bh, 0, 0x01 | 0x800);
        BITMAPINFO bi{};
        bi.bmiHeader.biSize = sizeof bi.bmiHeader;
        bi.bmiHeader.biWidth = bw;
        bi.bmiHeader.biHeight = -bh;
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        StretchDIBits(dc, x, y, rw, rh, 0, 0, bw, bh, px.data(), &bi, DIB_RGB_COLORS, SRCCOPY);
        api.BitmapDestroy(bmp);
      }
    }
    EndPage(dc);
    api.ClosePage(p);
    printed++;
  }
  EndDoc(dc);
  DeleteDC(dc);
  api.CloseDocument(doc);
  say("ok " + std::to_string(printed));
  return 0;
}

// A page object tagged as Keepnear's marks picture.
bool taggedMarks(OBJ o) {
  if (!api.CountMarks || !api.GetMark || !api.MarkGetName) return false;
  const int n = api.CountMarks(o);
  for (int i = 0; i < n; i++) {
    void* m = api.GetMark(o, (unsigned long)i);
    if (!m) continue;
    unsigned short buf[64] = {0};
    unsigned long len = 0;
    if (!api.MarkGetName(m, buf, sizeof buf, &len)) continue;
    std::wstring name;
    for (int k = 0; k < 64 && buf[k]; k++) name.push_back((wchar_t)buf[k]);
    if (name == L"KeepnearMarks") return true;
  }
  return false;
}

// An annotation's text value [key] (UTF-8).
std::string annotText(void* a, const char* key) {
  if (!api.AnnotGetString) return "";
  const unsigned long n = api.AnnotGetString(a, key, nullptr, 0);
  if (n <= 2) return "";
  std::vector<unsigned short> buf(n / 2 + 1, 0);
  api.AnnotGetString(a, key, buf.data(), n);
  std::wstring w;
  for (auto c : buf) {
    if (!c) break;
    w.push_back((wchar_t)c);
  }
  return narrow(w.c_str());
}

DOC openPdf(const std::string& pdf, std::vector<unsigned char>& bytes) {
  if (!readAll(pdf, bytes) || bytes.empty()) return nullptr;
  return api.LoadMemDocument(bytes.data(), (int)bytes.size(), nullptr);
}

// --clean: Keepnear's marks taken off, their data printed.
int cleanPdf(const std::string& pdf, const std::wstring& outPath) {
  if (!load() || !api.CountObjects || !api.GetObject || !api.RemoveObject || !api.AnnotCount || !api.GetAnnot ||
      !api.RemoveAnnot || !api.AnnotHasKey) {
    say("error pdfium.dll not usable");
    return 3;
  }
  api.InitLibrary();
  std::vector<unsigned char> bytes;
  DOC doc = openPdf(pdf, bytes);
  if (!doc) {
    say("error cannot open");
    return 1;
  }
  bool any = false;
  const int pages = api.GetPageCount(doc);
  for (int i = 0; i < pages; i++) {
    PAGE pg = api.LoadPage(doc, i);
    if (!pg) continue;
    bool changed = false;
    for (int k = api.CountObjects(pg) - 1; k >= 0; k--) {
      OBJ o = api.GetObject(pg, k);
      if (o && taggedMarks(o) && api.RemoveObject(pg, o)) {
        if (api.ObjDestroy) api.ObjDestroy(o);
        changed = true;
      }
    }
    for (int k = api.AnnotCount(pg) - 1; k >= 0; k--) {
      void* a = api.GetAnnot(pg, k);
      if (!a) continue;
      const bool data = api.AnnotHasKey(a, "KeepnearMarks") != 0;
      const bool note = api.AnnotHasKey(a, "KeepnearNote") != 0;
      if (data) {
        const std::string d = annotText(a, "KeepnearMarks");
        if (!d.empty()) say("marks " + std::to_string(i) + " " + d);
      }
      if (api.CloseAnnot) api.CloseAnnot(a);
      if (data || note) {
        api.RemoveAnnot(pg, k);
        any = true;
      }
    }
    if (changed) {
      api.GenerateContent(pg);
      any = true;
    }
    api.ClosePage(pg);
  }
  if (!any) {
    api.CloseDocument(doc);
    say("none");
    return 0;
  }
  FILE* f = _wfopen(outPath.c_str(), L"wb");
  bool ok = false;
  if (f) {
    Writer w{};
    w.version = 1;
    w.writeBlock = writeBlock;
    w.f = f;
    ok = api.SaveAsCopy(doc, &w, 0) != 0;
    fclose(f);
  }
  api.CloseDocument(doc);
  say(ok ? "ok" : "error save failed");
  return ok ? 0 : 1;
}

// --notes: every PDF text note, where it is on the page as shown.
int listNotes(const std::string& pdf) {
  if (!load() || !api.AnnotCount || !api.GetAnnot || !api.AnnotGetSubtype || !api.AnnotGetRect) {
    say("error pdfium.dll not usable");
    return 3;
  }
  api.InitLibrary();
  std::vector<unsigned char> bytes;
  DOC doc = openPdf(pdf, bytes);
  if (!doc) {
    say("error cannot open");
    return 1;
  }
  const int pages = api.GetPageCount(doc);
  for (int i = 0; i < pages; i++) {
    PAGE pg = api.LoadPage(doc, i);
    if (!pg) continue;
    const int rot = api.GetRotation(pg) & 3;
    const double dw = api.GetPageWidth(pg), dh = api.GetPageHeight(pg);
    const double W = (rot & 1) ? dh : dw, H = (rot & 1) ? dw : dh;
    float l = 0, b = 0, r = 0, t = 0;
    double x0 = 0, y0 = 0;
    if ((api.GetCropBox && api.GetCropBox(pg, &l, &b, &r, &t)) || (api.GetMediaBox && api.GetMediaBox(pg, &l, &b, &r, &t))) {
      x0 = l;
      y0 = b;
    }
    for (int k = 0; k < api.AnnotCount(pg); k++) {
      void* a = api.GetAnnot(pg, k);
      if (!a) continue;
      if (api.AnnotGetSubtype(a) == 1 /* text */) {
        std::string text = annotText(a, "Contents");
        float rc[4] = {0, 0, 0, 0};
        if (!text.empty() && api.AnnotGetRect(a, rc)) {
          const double ux = (rc[0] + rc[2]) / 2 - x0, uy = (rc[1] + rc[3]) / 2 - y0;
          double X, Y;
          switch (rot) {
            case 1: X = uy; Y = ux; break;
            case 2: X = W - ux; Y = uy; break;
            case 3: X = H - uy; Y = W - ux; break;
            default: X = ux; Y = H - uy; break;
          }
          const double sw = (rot & 1) ? H : W, sh = (rot & 1) ? W : H;
          std::string one;
          for (char c : text) {
            if (c == '\r') continue;
            if (c == '\n') one += "\xE2\x80\xA8";
            else one.push_back(c);
          }
          const bool own = api.AnnotHasKey && api.AnnotHasKey(a, "KeepnearNote");
          double nx = sw > 0 ? X / sw : 0, ny = sh > 0 ? Y / sh : 0;
          // A number's note: shown over the number itself.
          if (own) {
            const std::string at = annotText(a, "KeepnearAt");
            double ax = 0, ay = 0;
            if (!at.empty() && std::sscanf(at.c_str(), "%lf %lf", &ax, &ay) == 2) {
              nx = ax;
              ny = ay;
            }
          }
          char head[96];
          std::snprintf(head, sizeof head, "note %d %.5f %.5f %d ", i, nx, ny, own ? 1 : 0);
          say(head + one);
        }
      }
      if (api.CloseAnnot) api.CloseAnnot(a);
    }
    api.ClosePage(pg);
  }
  api.CloseDocument(doc);
  say("ok");
  return 0;
}

}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argc >= 5 && wcscmp(argv[1], L"--styles") == 0) {
    return styles(narrow(argv[2]), _wtoi(argv[3]), argv[4]);
  }
  if (argc >= 10 && wcscmp(argv[1], L"--print") == 0) {
    return printPdf(narrow(argv[2]), argv[3], _wtoi(argv[4]), narrow(argv[5]), _wtoi(argv[6]) != 0, _wtoi(argv[7]) != 0,
                    _wtoi(argv[8]) != 0, _wtoi(argv[9]) != 0);
  }
  if (argc >= 4 && wcscmp(argv[1], L"--clean") == 0) {
    return cleanPdf(narrow(argv[2]), argv[3]);
  }
  if (argc >= 3 && wcscmp(argv[1], L"--notes") == 0) {
    return listNotes(narrow(argv[2]));
  }
  if (argc >= 5 && wcscmp(argv[1], L"--thumb") == 0) {
    return thumb(narrow(argv[2]), narrow(argv[3]), _wtoi(argv[4]));
  }
  if (argc < 2) {
    say("error usage: lr_pdf.exe <plan>");
    return 2;
  }
  std::vector<unsigned char> planBytes;
  {
    FILE* f = _wfopen(argv[1], L"rb");
    if (!f) {
      say("error no plan");
      return 2;
    }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) planBytes.insert(planBytes.end(), buf, buf + n);
    fclose(f);
  }
  if (!load()) {
    say("error pdfium.dll not usable");
    return 3;
  }
  api.InitLibrary();
  DOC out = api.CreateNewDocument();
  std::string outPath;
  // Each source's bytes must stay while it is open.
  std::vector<std::vector<unsigned char>*> blobs;
  std::vector<DOC> docs;
  std::vector<std::vector<unsigned char>*> keep;
  int pages = 0;
  int skipped = 0;
  // Fonts loaded for EDIT (their bytes must stay until saved).
  std::vector<std::pair<std::string, FONT>> fonts;
  PAGE last = nullptr;
  int lastRot = 0;
  double lastW = 0, lastH = 0, lastX0 = 0, lastY0 = 0;
  std::string err;

  auto closeLast = [&]() {
    if (last) {
      api.GenerateContent(last);
      api.ClosePage(last);
      last = nullptr;
    }
  };

  std::string plan(planBytes.begin(), planBytes.end());
  if (plan.size() >= 3 && (unsigned char)plan[0] == 0xEF && (unsigned char)plan[1] == 0xBB && (unsigned char)plan[2] == 0xBF) plan = plan.substr(3);
  // Every letter each font file is wanted for (all EDIT lines first), so a
  // font goes in cut down to those letters (subset.h), not whole.
  std::map<std::string, std::set<uint32_t>> wanted;
  int cut = 0, whole = 0;
  for (auto& raw : split(plan, '\n')) {
    if (raw.rfind("EDIT ", 0) != 0) continue;
    auto p = split(raw.substr(5), '|');
    if (p.size() < 10 || p[8] == "obj" || p[8].rfind("objat:", 0) == 0) continue;
    std::string t9 = p[9];
    while (!t9.empty() && (t9.back() == '\r' || t9.back() == ' ')) t9.pop_back();
    std::vector<unsigned char> tb;
    auto& set = wanted[p[8]];
    set.insert(0x20);
    if (readAll(t9, tb)) subset::codePoints(std::string(tb.begin(), tb.end()), set);
  }
  for (auto& raw : split(plan, '\n')) {
    std::string line = raw;
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
    if (line.empty()) continue;
    size_t sp = line.find(' ');
    std::string cmd = line.substr(0, sp);
    std::string arg = sp == std::string::npos ? "" : line.substr(sp + 1);
    if (cmd == "OUT") {
      outPath = arg;
    } else if (cmd == "DOC") {
      auto* b = new std::vector<unsigned char>();
      if (!readAll(arg, *b)) {
        err = "cannot read " + arg;
        break;
      }
      DOC d = api.LoadMemDocument(b->data(), (int)b->size(), nullptr);
      if (!d) {
        err = "cannot open " + arg;
        break;
      }
      blobs.push_back(b);
      docs.push_back(d);
    } else if (cmd == "PAGE") {
      closeLast();
      auto p = split(arg, '|');
      if (p.size() < 3) continue;
      int di = atoi(p[0].c_str()), pi = atoi(p[1].c_str()), turn = atoi(p[2].c_str());
      if (di < 0 || di >= (int)docs.size() || pi < 0 || pi >= api.GetPageCount(docs[di])) continue;
      std::string range = std::to_string(pi + 1);
      if (!api.ImportPages(out, docs[di], range.c_str(), pages)) {
        err = "cannot take page";
        break;
      }
      last = api.LoadPage(out, pages);
      pages++;
      if (!last) continue;
      lastRot = api.GetRotation(last) & 3;
      double dw = api.GetPageWidth(last), dh = api.GetPageHeight(last);
      lastW = (lastRot & 1) ? dh : dw;
      lastH = (lastRot & 1) ? dw : dh;
      float l = 0, b = 0, r = 0, t = 0;
      lastX0 = 0;
      lastY0 = 0;
      if ((api.GetCropBox && api.GetCropBox(last, &l, &b, &r, &t)) || (api.GetMediaBox && api.GetMediaBox(last, &l, &b, &r, &t))) {
        lastX0 = l;
        lastY0 = b;
      }
      if (turn & 3) api.SetRotation(last, (lastRot + turn) & 3);
    } else if (cmd == "STAMP") {
      auto p = split(arg, '|');
      if (!last || p.size() < 7) continue;
      int pw = atoi(p[1].c_str()), ph = atoi(p[2].c_str());
      double x = atof(p[3].c_str()), y = atof(p[4].c_str()), w = atof(p[5].c_str()), h = atof(p[6].c_str());
      // Turned about its middle, clockwise as seen (radians).
      const double spin = p.size() > 7 ? atof(p[7].c_str()) : 0.0;
      auto* px = new std::vector<unsigned char>();
      if (!readAll(p[0], *px) || pw <= 0 || ph <= 0 || px->size() < (size_t)pw * ph * 4) {
        delete px;
        continue;
      }
      keep.push_back(px);
      // Size as shown: before our turn.
      double dW = (lastRot & 1) ? lastH : lastW, dH = (lastRot & 1) ? lastW : lastH;
      const double cs = cos(spin), sn = sin(spin);
      auto at = [&](double u, double v, double& ox, double& oy) {
        // From the middle, in shown units (y down), then turned.
        const double a = (u - 0.5) * w * dW, b = (0.5 - v) * h * dH;
        double X = (x + w / 2) * dW + a * cs - b * sn, Y = (y + h / 2) * dH + a * sn + b * cs;
        toPage(lastRot, lastW, lastH, X, Y, ox, oy);
        ox += lastX0;
        oy += lastY0;
      };
      double x00, y00, x10, y10, x01, y01;
      at(0, 0, x00, y00);
      at(1, 0, x10, y10);
      at(0, 1, x01, y01);
      BMP bmp = api.BitmapCreateEx(pw, ph, 4 /* BGRA */, px->data(), pw * 4);
      OBJ img = api.NewImageObj(out);
      if (!bmp || !img) continue;
      PAGE pg[1] = {last};
      if (api.SetBitmap(pg, 1, img, bmp)) {
        api.SetMatrix(img, x10 - x00, y10 - y00, x01 - x00, y01 - y00, x00, y00);
        // Keepnear's marks drawn as one picture: tagged, to be taken off
        // when they are changed again (--clean).
        if (p.size() > 8 && p[8] == "marks" && api.AddMark) api.AddMark(img, "KeepnearMarks");
        api.InsertObject(last, img);
      }
      api.BitmapDestroy(bmp);
    } else if (cmd == "MARKS") {
      // MARKS <file>: the marks' data in a hidden annotation.
      if (!last || !api.CreateAnnot || !api.AnnotSetString || !api.CloseAnnot) continue;
      std::vector<unsigned char> t;
      if (!readAll(arg, t) || t.empty()) continue;
      std::vector<unsigned short> u16(t.begin(), t.end());
      u16.push_back(0);
      void* a = api.CreateAnnot(last, 5 /* FPDF_ANNOT_SQUARE */);
      if (!a) continue;
      const float r[4] = {(float)lastX0, (float)lastY0, (float)lastX0, (float)lastY0};
      if (api.AnnotSetRect) api.AnnotSetRect(a, r);
      if (api.AnnotSetFlags) api.AnnotSetFlags(a, 2 /* hidden */ | 32 /* no view */);
      api.AnnotSetString(a, "KeepnearMarks", u16.data());
      api.CloseAnnot(a);
    } else if (cmd == "NOTE") {
      auto p = split(arg, '|');
      if (!last || p.size() < 3 || !api.CreateAnnot || !api.AnnotSetRect || !api.AnnotSetString || !api.CloseAnnot) continue;
      std::vector<unsigned char> t;
      if (!readAll(p[2], t)) continue;
      std::wstring text = wide(std::string(t.begin(), t.end()));
      std::vector<unsigned short> u16(text.begin(), text.end());
      u16.push_back(0);
      double dW = (lastRot & 1) ? lastH : lastW, dH = (lastRot & 1) ? lastW : lastH;
      double ox, oy;
      toPage(lastRot, lastW, lastH, atof(p[0].c_str()) * dW, atof(p[1].c_str()) * dH, ox, oy);
      ox += lastX0;
      oy += lastY0;
      void* a = api.CreateAnnot(last, 1 /* FPDF_ANNOT_TEXT */);
      if (!a) continue;
      const float r[4] = {(float)ox - 10, (float)oy + 10, (float)ox + 10, (float)oy - 10};  // left top right bottom
      api.AnnotSetRect(a, r);
      api.AnnotSetString(a, "Contents", u16.data());
      std::wstring who = L"Keepnear";
      std::vector<unsigned short> w16(who.begin(), who.end());
      w16.push_back(0);
      api.AnnotSetString(a, "T", w16.data());
      // From Keepnear's marks: taken off with them (--clean).
      const unsigned short one[2] = {'1', 0};
      api.AnnotSetString(a, "KeepnearNote", one);
      // What it is about (a number's middle, 0–1 of the page as shown): its
      // icon sits beside the number; Keepnear shows the words over the number.
      if (p.size() > 5 && !p[4].empty() && !p[5].empty()) {
        const std::string at = p[4] + " " + p[5];
        std::vector<unsigned short> a16(at.begin(), at.end());
        a16.push_back(0);
        api.AnnotSetString(a, "KeepnearAt", a16.data());
      }
      if (api.AnnotSetColor && p.size() > 3) {
        unsigned int rgb = (unsigned int)strtoul(p[3].c_str(), nullptr, 16);
        api.AnnotSetColor(a, 0, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF, 255);
      }
      api.CloseAnnot(a);
    } else if (cmd == "EDIT") {
      auto p = split(arg, '|');
      bool can = api.CountObjects && api.GetObject && api.ObjGetType && api.ObjGetBounds && api.RemoveObject && api.ObjDestroy &&
                 api.LoadFont && api.CreateTextObj && api.TextSetText && api.ObjSetFillColor && api.ObjTransform;
      if (!last || p.size() < 10 || !can) {
        skipped++;
        continue;
      }
      double L = atof(p[0].c_str()), B = atof(p[1].c_str()), R = atof(p[2].c_str()), T = atof(p[3].c_str());
      double X = atof(p[4].c_str()), base = atof(p[5].c_str()), size = atof(p[6].c_str());
      // The old text: objects whose middle is in the box. One that runs on
      // well outside it holds other text too: then leave the line alone.
      double tol = (T - B) * 0.35 + 1.5;
      std::vector<OBJ> old;
      bool mixed = false;
      int n = api.CountObjects(last);
      for (int i = 0; i < n; i++) {
        OBJ o = api.GetObject(last, i);
        if (!o || api.ObjGetType(o) != 1 /* text */) continue;
        float l = 0, b = 0, r = 0, t = 0;
        if (!api.ObjGetBounds(o, &l, &b, &r, &t)) continue;
        double cx = (l + r) / 2, cy = (b + t) / 2;
        if (cx < L - tol || cx > R + tol || cy < B - tol || cy > T + tol) continue;
        if (l < L - tol * 2 || r > R + tol * 2 || b < B - tol * 2 || t > T + tol * 2) {
          mixed = true;
          break;
        }
        old.push_back(o);
      }
      if (mixed || old.empty()) {
        skipped++;
        continue;
      }
      std::vector<unsigned char> textBytes;
      if (!readAll(p[9], textBytes)) {
        skipped++;
        continue;
      }
      // fake: 1 = bold, 2 = italic (the font file has no such face).
      int fake = p.size() > 10 ? atoi(p[10].c_str()) : 0;
      // "obj": the very font the old text used (all the new letters are in
      // it); "objat:x,y": the font of the text at that point of this page.
      FONT font = nullptr;
      OBJ like = nullptr;
      if (p[8] == "obj") {
        like = old[0];
      } else if (p[8].rfind("objat:", 0) == 0) {
        double px = atof(p[8].c_str() + 6);
        const char* comma = strchr(p[8].c_str() + 6, ',');
        double py = comma ? atof(comma + 1) : 0;
        int cnt = api.CountObjects(last);
        for (int i = 0; i < cnt && !like; i++) {
          OBJ o = api.GetObject(last, i);
          if (!o || api.ObjGetType(o) != 1) continue;
          float l = 0, b = 0, r = 0, t = 0;
          if (api.ObjGetBounds(o, &l, &b, &r, &t) && px >= l && px <= r && py >= b && py <= t) like = o;
        }
      }
      if (like && api.TextObjGetFont) font = api.TextObjGetFont(like);
      for (auto& f : fonts) {
        if (!font && f.first == p[8]) font = f.second;
      }
      if (!font) {
        auto* fb = new std::vector<unsigned char>();
        if (readAll(p[8], *fb)) {
          // Only the letters used; the whole font if that can't be done.
          std::vector<unsigned char> small;
          auto w = wanted.find(p[8]);
          if (w != wanted.end() && subset::make(*fb, w->second, small)) {
            font = api.LoadFont(out, small.data(), (unsigned int)small.size(), 2 /* TrueType */, 1 /* CID */);
            if (font) {
              fb->swap(small);
              cut++;
            }
          }
          if (!font) {
            font = api.LoadFont(out, fb->data(), (unsigned int)fb->size(), 2 /* TrueType */, 1 /* CID */);
            if (font) whole++;
          }
        }
        if (!font) {
          delete fb;
          skipped++;
          continue;
        }
        keep.push_back(fb);
        fonts.push_back({p[8], font});
      }
      unsigned int cr = 0, cg = 0, cb = 0, ca = 255;
      if (p[7] == "auto") {
        if (!api.ObjGetFillColor || !api.ObjGetFillColor(old[0], &cr, &cg, &cb, &ca)) cr = cg = cb = 0;
      } else {
        unsigned long v = strtoul(p[7].c_str(), nullptr, 16);
        cr = (v >> 16) & 255;
        cg = (v >> 8) & 255;
        cb = v & 255;
      }
      std::string text(textBytes.begin(), textBytes.end());
      std::wstring w = wide(text);
      // Made before the old text goes (the reused font stays alive).
      OBJ to = nullptr;
      if (!w.empty()) {
        float rawSize = (float)size;
        double ma = 1, mb = 0, mc = 0, md = 1;
        if (like && api.TextObjGetFontSize && api.ObjGetMatrix) {
          // Drawn exactly like the text it copies: its size and matrix
          // (so a slanted or squeezed text stays so).
          float fs = 0;
          Matrix m{1, 0, 0, 1, 0, 0};
          if (api.TextObjGetFontSize(like, &fs) && api.ObjGetMatrix(like, &m) && fs > 0) {
            double sy = sqrt((double)m.c * m.c + (double)m.d * m.d);
            double k = sy > 0 ? size / (fs * sy) : 1;
            rawSize = fs;
            ma = m.a * k;
            mb = m.b * k;
            mc = m.c * k;
            md = m.d * k;
          }
        } else if (fake & 2) {
          mc = 0.21;  // about 12 degrees, like an italic
        }
        to = api.CreateTextObj(out, font, rawSize);
        if (to) {
          std::vector<unsigned short> u(w.begin(), w.end());
          u.push_back(0);
          api.TextSetText(to, u.data());
          api.ObjSetFillColor(to, cr, cg, cb, 255);
          if ((fake & 1) && api.TextObjSetRenderMode && api.ObjSetStrokeColor && api.ObjSetStrokeWidth) {
            // Bold drawn by outlining the letters too (fill + stroke).
            api.TextObjSetRenderMode(to, 2);
            api.ObjSetStrokeColor(to, cr, cg, cb, 255);
            api.ObjSetStrokeWidth(to, (float)(rawSize * 0.035));
          }
          api.ObjTransform(to, ma, mb, mc, md, X, base);
        }
      }
      for (OBJ o : old) {
        if (api.RemoveObject(last, o)) api.ObjDestroy(o);
      }
      if (to) api.InsertObject(last, to);
    } else if (cmd == "IMAGE") {
      closeLast();
      auto p = split(arg, '|');
      if (p.size() < 7) continue;
      auto* jpg = new std::vector<unsigned char>();
      if (!readAll(p[0], *jpg)) {
        delete jpg;
        err = "cannot read " + p[0];
        break;
      }
      keep.push_back(jpg);
      double pw = atof(p[1].c_str()), ph = atof(p[2].c_str());
      double x = atof(p[3].c_str()), y = atof(p[4].c_str()), w = atof(p[5].c_str()), h = atof(p[6].c_str());
      PAGE pg = api.NewPage(out, pages, pw, ph);
      if (!pg) {
        err = "cannot make page";
        break;
      }
      pages++;
      OBJ img = api.NewImageObj(out);
      FileAccess fa{(unsigned long)jpg->size(), getBlock, jpg};
      PAGE arr[1] = {pg};
      if (img && api.LoadJpegFileInline(arr, 1, img, &fa)) {
        api.SetMatrix(img, w, 0, 0, h, x, y);
        api.InsertObject(pg, img);
      }
      last = pg;
      lastRot = 0;
    }
  }
  closeLast();
  if (err.empty() && outPath.empty()) err = "no OUT";
  if (err.empty() && pages == 0) err = "no pages";
  if (err.empty()) {
    FILE* f = _wfopen(wide(outPath).c_str(), L"wb");
    if (!f) {
      err = "cannot write " + outPath;
    } else {
      Writer w{};
      w.version = 1;
      w.writeBlock = writeBlock;
      w.f = f;
      bool ok = api.SaveAsCopy(out, &w, 0) != 0;
      fclose(f);
      if (!ok) err = "save failed";
    }
  }
  // The fonts belong to the new document: closed before it.
  if (api.FontClose) {
    for (auto& f : fonts) api.FontClose(f.second);
  }
  api.CloseDocument(out);
  for (DOC d : docs) api.CloseDocument(d);
  for (auto* b : blobs) delete b;
  for (auto* b : keep) delete b;
  if (!err.empty()) {
    say("error " + err);
    return 1;
  }
  say("ok " + std::to_string(pages) + (skipped ? " skipped " + std::to_string(skipped) : "") +
      (cut || whole ? " fonts " + std::to_string(cut) + " cut " + std::to_string(whole) + " whole" : ""));
  return 0;
}
