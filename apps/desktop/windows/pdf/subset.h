// apps/desktop/windows/pdf/subset.h
// A TrueType font cut down to the letters used: only their glyphs (and
// the glyphs they are built from) are kept, numbered afresh, with a new
// character map. A changed word then adds a few KB to the PDF instead of
// the whole font (Microsoft YaHei Bold: about 10 MB).
//
// Plain TrueType (glyf) fonts only; anything else (CFF / OpenType outlines,
// a damaged file) returns false and the whole font is used as before.
// Kept: cmap glyf loca head hhea hmtx maxp post(v3) OS/2 name cvt fpgm prep
// gasp. Dropped: layout, bitmaps, kerning, vertical metrics — not needed
// to draw the letters in a PDF.

#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace subset {

inline uint16_t u16(const std::vector<unsigned char>& b, size_t o) { return (uint16_t)((b[o] << 8) | b[o + 1]); }
inline uint32_t u32(const std::vector<unsigned char>& b, size_t o) {
  return ((uint32_t)b[o] << 24) | ((uint32_t)b[o + 1] << 16) | ((uint32_t)b[o + 2] << 8) | b[o + 3];
}
inline void p16(std::vector<unsigned char>& b, size_t o, uint32_t v) {
  b[o] = (unsigned char)(v >> 8);
  b[o + 1] = (unsigned char)v;
}
inline void p32(std::vector<unsigned char>& b, size_t o, uint32_t v) {
  b[o] = (unsigned char)(v >> 24);
  b[o + 1] = (unsigned char)(v >> 16);
  b[o + 2] = (unsigned char)(v >> 8);
  b[o + 3] = (unsigned char)v;
}
inline void a16(std::vector<unsigned char>& b, uint32_t v) {
  b.push_back((unsigned char)(v >> 8));
  b.push_back((unsigned char)v);
}
inline void a32(std::vector<unsigned char>& b, uint32_t v) {
  a16(b, v >> 16);
  a16(b, v & 0xFFFF);
}

struct Table {
  size_t off = 0, len = 0;
  bool ok = false;
};

// The glyph for code point [c] in the (3,10) format 12 or (3,1) / (0,x)
// format 4 character map; 0 when none.
inline uint32_t glyphOf(const std::vector<unsigned char>& f, const Table& cmap, uint32_t c) {
  const size_t base = cmap.off;
  if (cmap.len < 4) return 0;
  const uint16_t n = u16(f, base + 2);
  size_t best12 = 0, best4 = 0;
  for (uint16_t i = 0; i < n; i++) {
    const size_t r = base + 4 + i * 8;
    if (r + 8 > base + cmap.len) return 0;
    const uint16_t pid = u16(f, r), eid = u16(f, r + 2);
    const size_t at = base + u32(f, r + 4);
    if (at + 4 > f.size()) continue;
    const uint16_t fmt = u16(f, at);
    if (fmt == 12 && (pid == 3 || pid == 0) && !best12) best12 = at;
    if (fmt == 4 && ((pid == 3 && (eid == 1 || eid == 0)) || pid == 0) && !best4) best4 = at;
  }
  if (best12) {
    const size_t at = best12;
    if (at + 16 > f.size()) return 0;
    const uint32_t groups = u32(f, at + 12);
    if (at + 16 + (size_t)groups * 12 > f.size()) return 0;
    for (uint32_t g = 0; g < groups; g++) {
      const size_t r = at + 16 + (size_t)g * 12;
      const uint32_t s = u32(f, r), e = u32(f, r + 4);
      if (c >= s && c <= e) return u32(f, r + 8) + (c - s);
    }
    return 0;
  }
  if (best4 && c <= 0xFFFF) {
    const size_t at = best4;
    if (at + 14 > f.size()) return 0;
    const uint16_t seg2 = u16(f, at + 6);
    const size_t ends = at + 14, starts = ends + seg2 + 2, deltas = starts + seg2, ranges = deltas + seg2;
    if (ranges + seg2 > f.size()) return 0;
    for (uint16_t i = 0; i < seg2 / 2; i++) {
      const uint16_t e = u16(f, ends + i * 2);
      if (c > e) continue;
      const uint16_t s = u16(f, starts + i * 2);
      if (c < s) return 0;
      const uint16_t d = u16(f, deltas + i * 2), ro = u16(f, ranges + i * 2);
      if (ro == 0) return (c + d) & 0xFFFF;
      const size_t g = ranges + i * 2 + ro + (c - s) * 2;
      if (g + 2 > f.size()) return 0;
      const uint16_t v = u16(f, g);
      return v ? (v + d) & 0xFFFF : 0;
    }
  }
  return 0;
}

// [font]: a .ttf file's bytes; [chars]: the code points wanted. On true,
// [out] holds the smaller font.
inline bool make(const std::vector<unsigned char>& f, const std::set<uint32_t>& chars, std::vector<unsigned char>& out) {
  if (f.size() < 12) return false;
  const uint32_t ver = u32(f, 0);
  if (ver != 0x00010000 && ver != 0x74727565 /* 'true' */) return false;
  const uint16_t nt = u16(f, 4);
  if (12 + (size_t)nt * 16 > f.size()) return false;
  std::map<std::string, Table> t;
  for (uint16_t i = 0; i < nt; i++) {
    const size_t r = 12 + i * 16;
    std::string tag(reinterpret_cast<const char*>(&f[r]), 4);
    Table x;
    x.off = u32(f, r + 8);
    x.len = u32(f, r + 12);
    x.ok = x.off + x.len <= f.size();
    if (x.ok) t[tag] = x;
  }
  for (const char* need : {"cmap", "glyf", "loca", "head", "hhea", "hmtx", "maxp"}) {
    if (!t.count(need)) return false;
  }
  const Table &head = t["head"], &hhea = t["hhea"], &maxp = t["maxp"], &loca = t["loca"], &glyf = t["glyf"], &hmtx = t["hmtx"];
  if (head.len < 54 || hhea.len < 36 || maxp.len < 6) return false;
  const uint16_t numGlyphs = u16(f, maxp.off + 4);
  const bool longLoca = u16(f, head.off + 50) != 0;
  if (loca.len < (size_t)(numGlyphs + 1) * (longLoca ? 4 : 2)) return false;
  auto glyphAt = [&](uint32_t g, size_t& o, size_t& n) {
    if (g >= numGlyphs) return false;
    size_t a, b;
    if (longLoca) {
      a = u32(f, loca.off + g * 4);
      b = u32(f, loca.off + g * 4 + 4);
    } else {
      a = (size_t)u16(f, loca.off + g * 2) * 2;
      b = (size_t)u16(f, loca.off + g * 2 + 2) * 2;
    }
    if (b < a || glyf.off + b > glyf.off + glyf.len) return false;
    o = glyf.off + a;
    n = b - a;
    return true;
  };

  // The glyphs: .notdef, those of the letters, and their parts.
  std::map<uint32_t, uint32_t> charGlyph;
  std::set<uint32_t> keep{0};
  for (uint32_t c : chars) {
    const uint32_t g = glyphOf(f, t["cmap"], c);
    if (g && g < numGlyphs) {
      charGlyph[c] = g;
      keep.insert(g);
    }
  }
  std::vector<uint32_t> todo(keep.begin(), keep.end());
  while (!todo.empty()) {
    const uint32_t g = todo.back();
    todo.pop_back();
    size_t o, n;
    if (!glyphAt(g, o, n)) return false;
    if (n < 10 || (int16_t)u16(f, o) >= 0) continue;
    size_t p = o + 10;
    for (;;) {
      if (p + 4 > o + n) return false;
      const uint16_t flags = u16(f, p), part = u16(f, p + 2);
      if (part >= numGlyphs) return false;
      if (keep.insert(part).second) todo.push_back(part);
      p += 4 + ((flags & 0x0001) ? 4 : 2);
      if (flags & 0x0008) p += 2;
      else if (flags & 0x0040) p += 4;
      else if (flags & 0x0080) p += 8;
      if (!(flags & 0x0020)) break;
    }
  }
  std::vector<uint32_t> olds(keep.begin(), keep.end());
  std::map<uint32_t, uint32_t> renum;
  for (size_t i = 0; i < olds.size(); i++) renum[olds[i]] = (uint32_t)i;
  const uint32_t count = (uint32_t)olds.size();

  // glyf + loca (long offsets); parts point at their new numbers.
  std::vector<unsigned char> nglyf, nloca;
  for (uint32_t g : olds) {
    a32(nloca, (uint32_t)nglyf.size());
    size_t o, n;
    if (!glyphAt(g, o, n)) return false;
    const size_t at = nglyf.size();
    nglyf.insert(nglyf.end(), f.begin() + o, f.begin() + o + n);
    if (n >= 10 && (int16_t)u16(f, o) < 0) {
      size_t p = at + 10;
      for (;;) {
        const uint16_t flags = u16(nglyf, p);
        p16(nglyf, p + 2, renum[u16(nglyf, p + 2)]);
        p += 4 + ((flags & 0x0001) ? 4 : 2);
        if (flags & 0x0008) p += 2;
        else if (flags & 0x0040) p += 4;
        else if (flags & 0x0080) p += 8;
        if (!(flags & 0x0020)) break;
      }
    }
    while (nglyf.size() % 4) nglyf.push_back(0);
  }
  a32(nloca, (uint32_t)nglyf.size());

  // hmtx: an advance and a side bearing for every glyph.
  const uint16_t nhm = u16(f, hhea.off + 34);
  if (nhm == 0 || hmtx.len < (size_t)nhm * 4) return false;
  std::vector<unsigned char> nhmtx;
  for (uint32_t g : olds) {
    uint16_t adv, lsb;
    if (g < nhm) {
      adv = u16(f, hmtx.off + g * 4);
      lsb = u16(f, hmtx.off + g * 4 + 2);
    } else {
      adv = u16(f, hmtx.off + (nhm - 1) * 4);
      const size_t l = hmtx.off + nhm * 4 + (g - nhm) * 2;
      lsb = l + 2 <= hmtx.off + hmtx.len ? u16(f, l) : 0;
    }
    a16(nhmtx, adv);
    a16(nhmtx, lsb);
  }

  // cmap: (3,1) format 4 for the letters up to U+FFFF; (3,10) format 12
  // too when there are letters beyond.
  std::vector<std::pair<uint32_t, uint32_t>> bmp, all;
  for (auto& [c, g] : charGlyph) {
    all.push_back({c, renum[g]});
    if (c <= 0xFFFF) bmp.push_back({c, renum[g]});
  }
  const bool wide = all.size() != bmp.size();
  std::vector<unsigned char> f4;
  {
    const uint16_t segs = (uint16_t)(bmp.size() + 1);
    uint16_t sr = 1, es = 0;
    while (sr * 2 <= segs) {
      sr *= 2;
      es++;
    }
    sr *= 2;
    a16(f4, 4);
    a16(f4, 16 + segs * 8);
    a16(f4, 0);
    a16(f4, segs * 2);
    a16(f4, sr);
    a16(f4, es);
    a16(f4, segs * 2 - sr);
    for (auto& [c, g] : bmp) a16(f4, c);
    a16(f4, 0xFFFF);
    a16(f4, 0);
    for (auto& [c, g] : bmp) a16(f4, c);
    a16(f4, 0xFFFF);
    for (auto& [c, g] : bmp) a16(f4, (g - c) & 0xFFFF);
    a16(f4, 1);
    for (size_t i = 0; i < segs; i++) a16(f4, 0);
  }
  std::vector<unsigned char> f12;
  if (wide) {
    a16(f12, 12);
    a16(f12, 0);
    a32(f12, 16 + (uint32_t)all.size() * 12);
    a32(f12, 0);
    a32(f12, (uint32_t)all.size());
    for (auto& [c, g] : all) {
      a32(f12, c);
      a32(f12, c);
      a32(f12, g);
    }
  }
  std::vector<unsigned char> ncmap;
  a16(ncmap, 0);
  a16(ncmap, wide ? 2 : 1);
  const uint32_t first = wide ? 20 : 12;
  a16(ncmap, 3);
  a16(ncmap, 1);
  a32(ncmap, first);
  if (wide) {
    a16(ncmap, 3);
    a16(ncmap, 10);
    a32(ncmap, first + (uint32_t)f4.size());
  }
  ncmap.insert(ncmap.end(), f4.begin(), f4.end());
  ncmap.insert(ncmap.end(), f12.begin(), f12.end());

  auto copy = [&](const Table& x) { return std::vector<unsigned char>(f.begin() + x.off, f.begin() + x.off + x.len); };
  std::map<std::string, std::vector<unsigned char>> out_t;
  out_t["cmap"] = ncmap;
  out_t["glyf"] = nglyf;
  out_t["loca"] = nloca;
  out_t["hmtx"] = nhmtx;
  auto nhead = copy(head);
  p32(nhead, 8, 0);
  p16(nhead, 50, 1);
  out_t["head"] = nhead;
  auto nhhea = copy(hhea);
  p16(nhhea, 34, count);
  out_t["hhea"] = nhhea;
  auto nmaxp = copy(maxp);
  p16(nmaxp, 4, count);
  out_t["maxp"] = nmaxp;
  if (t.count("post") && t["post"].len >= 32) {
    auto post = std::vector<unsigned char>(f.begin() + t["post"].off, f.begin() + t["post"].off + 32);
    p32(post, 0, 0x00030000);
    out_t["post"] = post;
  }
  for (const char* tag : {"OS/2", "name", "cvt ", "fpgm", "prep", "gasp"}) {
    if (t.count(tag)) out_t[tag] = copy(t[tag]);
  }

  // The file: header, table records (sorted by tag), tables on 4 bytes.
  const uint16_t n = (uint16_t)out_t.size();
  uint16_t sr = 1, es = 0;
  while (sr * 2 <= n) {
    sr *= 2;
    es++;
  }
  sr *= 16;
  out.clear();
  a32(out, 0x00010000);
  a16(out, n);
  a16(out, sr);
  a16(out, es);
  a16(out, n * 16 - sr);
  size_t at = 12 + (size_t)n * 16;
  for (auto& [tag, data] : out_t) {
    uint32_t sum = 0;
    for (size_t i = 0; i < data.size(); i += 4) {
      uint32_t w = 0;
      for (size_t k = 0; k < 4; k++) w = (w << 8) | (i + k < data.size() ? data[i + k] : 0);
      sum += w;
    }
    out.insert(out.end(), tag.begin(), tag.end());
    a32(out, sum);
    a32(out, (uint32_t)at);
    a32(out, (uint32_t)data.size());
    at += (data.size() + 3) & ~(size_t)3;
  }
  size_t headAt = 0;
  for (auto& [tag, data] : out_t) {
    if (tag == "head") headAt = out.size();
    out.insert(out.end(), data.begin(), data.end());
    while (out.size() % 4) out.push_back(0);
  }
  uint32_t total = 0;
  for (size_t i = 0; i + 4 <= out.size(); i += 4) total += u32(out, i);
  p32(out, headAt + 8, 0xB1B0AFBA - total);
  return count > 1;
}

// The code points of UTF-8 [s].
inline void codePoints(const std::string& s, std::set<uint32_t>& to) {
  for (size_t i = 0; i < s.size();) {
    const unsigned char c = (unsigned char)s[i];
    uint32_t cp;
    int more;
    if (c < 0x80) {
      cp = c;
      more = 0;
    } else if ((c >> 5) == 6) {
      cp = c & 0x1F;
      more = 1;
    } else if ((c >> 4) == 14) {
      cp = c & 0x0F;
      more = 2;
    } else if ((c >> 3) == 30) {
      cp = c & 0x07;
      more = 3;
    } else {
      i++;
      continue;
    }
    if (i + more >= s.size() + (more ? 0 : 1)) break;
    for (int k = 1; k <= more; k++) cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3F);
    to.insert(cp);
    i += 1 + more;
  }
}

}  // namespace subset
