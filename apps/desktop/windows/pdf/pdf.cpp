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
//
//   lr_pdf.exe "<plan file>"
// Prints: ok <pages>   or   error <why>
//
// pdfium.dll (shipped for the PDF viewer) is loaded from the exe's folder;
// the text of pages taken from PDFs stays text (a signature is laid on top).

#include <windows.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

typedef void* DOC;
typedef void* PAGE;
typedef void* OBJ;
typedef void* BMP;

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

}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
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
      auto* px = new std::vector<unsigned char>();
      if (!readAll(p[0], *px) || pw <= 0 || ph <= 0 || px->size() < (size_t)pw * ph * 4) {
        delete px;
        continue;
      }
      keep.push_back(px);
      // Size as shown: before our turn.
      double dW = (lastRot & 1) ? lastH : lastW, dH = (lastRot & 1) ? lastW : lastH;
      auto at = [&](double u, double v, double& ox, double& oy) {
        double X = (x + u * w) * dW, Y = (y + (1 - v) * h) * dH;
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
        api.InsertObject(last, img);
      }
      api.BitmapDestroy(bmp);
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
  api.CloseDocument(out);
  for (DOC d : docs) api.CloseDocument(d);
  for (auto* b : blobs) delete b;
  for (auto* b : keep) delete b;
  if (!err.empty()) {
    say("error " + err);
    return 1;
  }
  say("ok " + std::to_string(pages));
  return 0;
}
