import sys, json, importlib, os
sys.path.insert(0, os.path.dirname(__file__))
from lib import STAMPS, PACKS
from conv import convert

mods = sys.argv[1].split(',')
for m in mods:
    importlib.import_module(m)

out = []
seen = set()
for s in STAMPS:
    assert s['id'] not in seen, s['id']
    seen.add(s['id'])
    sh = convert(s['svg'])
    out.append({'id': s['id'], 'p': s['pack'], 'zh': s['zh'], 'en': s['en'], 'ed': 1 if s['ed'] else 0, 's': sh})


def back(sh, size=110):
    """The converted shape drawn again (to check the conversion)."""
    a = sh['a']
    W, H = (size, size / a) if a >= 1 else (size * a, size)
    els = []
    for p in sh['p']:
        c = p.get('c', 0xff000000)
        rgba = f"rgba({(c>>16)&255},{(c>>8)&255},{c&255},{((c>>24)&255)/255:.3f})"
        if 't' in p:
            els.append(f'<text x="{p["x"]*W}" y="{p["y"]*H + p["s"]*H*0.36}" font-size="{p["s"]*H}" fill="{rgba}" font-weight="800" text-anchor="middle" font-family="Segoe UI,Arial">{p["t"]}</text>')
            continue
        for poly in p['d']:
            pts = ' '.join(f'{poly[i]*W:.1f},{poly[i+1]*H:.1f}' for i in range(0, len(poly), 2))
            if p.get('f') == 0:
                els.append(f'<polyline points="{pts}" fill="none" stroke="{rgba}" stroke-width="{p["w"]*H:.2f}" stroke-linecap="round" stroke-linejoin="round"/>')
            else:
                els.append(f'<polygon points="{pts}" fill="{rgba}"/>')
    return f'<svg width="{W:.0f}" height="{H:.0f}" viewBox="0 0 {W:.1f} {H:.1f}">{"".join(els)}</svg>'


html = ['<!doctype html><meta charset="utf-8"><style>body{margin:0;background:#f3f6fc;font-family:"Noto Sans CJK SC",sans-serif}h2{margin:14px 20px 6px;color:#2f6bff;font-size:16px}.g{display:flex;flex-wrap:wrap;gap:10px;margin:0 20px}.c{background:#fff;border-radius:12px;width:128px;padding:8px 4px;text-align:center;box-shadow:0 3px 10px #1d3b8a14}.c div{font-size:11px;margin-top:2px;height:28px;overflow:hidden}svg{display:block;margin:auto}</style>']
cur = None
for s in out:
    if s['p'] != cur:
        if cur is not None:
            html.append('</div>')
        cur = s['p']
        zh, en, kind = PACKS[cur]
        html.append(f'<h2>{zh} · {en}</h2><div class="g">')
    html.append(f'<div class="c">{back(s["s"])}<div>{s["zh"]}<br>{s["en"]}</div></div>')
html.append('</div>')
open(os.path.join(os.path.dirname(__file__), 'preview.html'), 'w').write(''.join(html))

data = {'packs': {k: list(v) for k, v in PACKS.items()}, 'stamps': out}
js = json.dumps(data, ensure_ascii=False, separators=(',', ':'))
open(os.path.join(os.path.dirname(__file__), 'real.json'), 'w').write(js)
print(len(out), 'stamps', len(js) // 1024, 'KB')

dart = ("// packages/ink/lib/src/packs/real.g.dart\n// Generated from SVG drawings (realistic, coloured stamps). Do not edit by hand.\n"
        "part of '../stamp_packs.dart';\n\nconst String _realJson = r'''" + js + "''';\n")
assert "'''" not in js
open('' + os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'packages') + '/ink/lib/src/packs/real.g.dart', 'w').write(dart)
