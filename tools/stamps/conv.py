# SVG (a small subset) -> StampShape JSON parts.
import math, re, json
import xml.etree.ElementTree as ET
from svg.path import parse_path

NAMED = {'none': None, 'white': '#ffffff', 'black': '#000000', 'red': '#ff0000', 'transparent': None}


def col(v, defs):
    if v is None:
        return None
    v = v.strip()
    if v in NAMED:
        return NAMED[v]
    m = re.match(r'url\(#([^)]+)\)', v)
    if m:
        return defs.get(m.group(1))
    if v.startswith('#'):
        if len(v) == 4:
            v = '#' + ''.join(c * 2 for c in v[1:])
        return v.lower()
    return None


def argb(hexcol, alpha):
    r, g, b = int(hexcol[1:3], 16), int(hexcol[3:5], 16), int(hexcol[5:7], 16)
    a = max(0, min(255, round(alpha * 255)))
    return (a << 24) | (r << 16) | (g << 8) | b


def mat_mul(a, b):
    return (a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
            a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
            a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5])


def parse_tf(t):
    m = (1, 0, 0, 1, 0, 0)
    if not t:
        return m
    for name, args in re.findall(r'(\w+)\s*\(([^)]*)\)', t):
        a = [float(x) for x in re.split(r'[\s,]+', args.strip()) if x]
        if name == 'translate':
            n = (1, 0, 0, 1, a[0], a[1] if len(a) > 1 else 0)
        elif name == 'scale':
            n = (a[0], 0, 0, a[1] if len(a) > 1 else a[0], 0, 0)
        elif name == 'rotate':
            r = math.radians(a[0])
            c, s = math.cos(r), math.sin(r)
            n = (c, s, -s, c, 0, 0)
            if len(a) == 3:
                n = mat_mul(mat_mul((1, 0, 0, 1, a[1], a[2]), n), (1, 0, 0, 1, -a[1], -a[2]))
        elif name == 'matrix':
            n = tuple(a)
        else:
            continue
        m = mat_mul(m, n)
    return m


def apply(m, p):
    x, y = p
    return (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])


def ellipse_pts(cx, cy, rx, ry, n=None):
    n = n or max(16, min(72, int((rx + ry) * 0.9)))
    return [(cx + rx * math.cos(2 * math.pi * k / n), cy + ry * math.sin(2 * math.pi * k / n)) for k in range(n)] + [(cx + rx, cy)]


def rrect_pts(x, y, w, h, rx, ry):
    rx = min(rx, w / 2)
    ry = min(ry, h / 2)
    if rx <= 0 or ry <= 0:
        return [(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)]
    pts = []
    for cx, cy, a0 in ((x + w - rx, y + ry, -90), (x + w - rx, y + h - ry, 0), (x + rx, y + h - ry, 90), (x + rx, y + ry, 180)):
        for k in range(7):
            a = math.radians(a0 + 90 * k / 6)
            pts.append((cx + rx * math.cos(a), cy + ry * math.sin(a)))
    pts.append(pts[0])
    return pts


def path_polys(d):
    p = parse_path(d)
    polys, cur = [], []
    last_end = None
    for seg in p:
        name = type(seg).__name__
        if name == 'Move':
            if len(cur) > 1:
                polys.append(cur)
            cur = [(seg.start.real, seg.start.imag)]
            last_end = seg.start
            continue
        if last_end is not None and abs(seg.start - last_end) > 1e-6:
            if len(cur) > 1:
                polys.append(cur)
            cur = [(seg.start.real, seg.start.imag)]
        if name in ('Line', 'Close'):
            cur.append((seg.end.real, seg.end.imag))
        else:
            ln = seg.length(error=1e-3)
            n = max(4, min(48, int(ln / 2.5)))
            for k in range(1, n + 1):
                q = seg.point(k / n)
                cur.append((q.real, q.imag))
        last_end = seg.end
        if name == 'Close':
            polys.append(cur)
            cur = []
            last_end = None
    if len(cur) > 1:
        polys.append(cur)
    return polys


def simplify(pts, tol):
    if len(pts) < 3:
        return pts
    # A closed outline: split at the point farthest from the start.
    if math.hypot(pts[0][0] - pts[-1][0], pts[0][1] - pts[-1][1]) < 1e-6 and len(pts) > 3:
        far = max(range(len(pts)), key=lambda i: math.hypot(pts[i][0] - pts[0][0], pts[i][1] - pts[0][1]))
        if 0 < far < len(pts) - 1:
            return simplify(pts[:far + 1], tol)[:-1] + simplify(pts[far:], tol)
    # Ramer–Douglas–Peucker
    def rdp(a, b):
        (x1, y1), (x2, y2) = pts[a], pts[b]
        dx, dy = x2 - x1, y2 - y1
        L = math.hypot(dx, dy) or 1e-9
        best, idx = 0, -1
        for i in range(a + 1, b):
            x0, y0 = pts[i]
            d = abs(dy * x0 - dx * y0 + x2 * y1 - y2 * x1) / L
            if d > best:
                best, idx = d, i
        if best > tol:
            return rdp(a, idx)[:-1] + rdp(idx, b)
        return [pts[a], pts[b]]
    return rdp(0, len(pts) - 1)


def convert(svg_text):
    root = ET.fromstring(svg_text)
    vb = [float(x) for x in root.get('viewBox').split()]
    W, H = vb[2], vb[3]
    ox, oy = vb[0], vb[1]
    defs = {}
    for el in root.iter():
        tag = el.tag.split('}')[-1]
        if tag in ('linearGradient', 'radialGradient'):
            stops = [s for s in el if s.tag.split('}')[-1] == 'stop']
            if stops:
                # The middle stop's colour stands for the gradient.
                defs[el.get('id')] = col(stops[len(stops) // 2].get('stop-color'), {})
    parts = []

    def norm(p):
        return [round((p[0] - ox) / W, 4), round((p[1] - oy) / H, 4)]

    def emit_shape(polys, st, m, closed):
        fill = col(st.get('fill', '#000000'), defs)
        stroke = col(st.get('stroke'), defs)
        op = float(st.get('opacity', 1))
        sw = float(st.get('stroke-width', 1))
        scale = math.sqrt(abs(m[0] * m[3] - m[1] * m[2]))
        tp = [[apply(m, q) for q in poly] for poly in polys]
        tp = [simplify(poly, 0.25) for poly in tp]
        if fill and closed:
            parts.append({'d': [[c for q in poly for c in norm(q)] for poly in tp if len(poly) > 2],
                          'c': argb(fill, op * float(st.get('fill-opacity', 1)))})
        if stroke:
            sp = [poly + [poly[0]] if closed and poly[0] != poly[-1] else poly for poly in tp]
            dash = st.get('stroke-dasharray')
            if dash:
                on, off = [float(x) * scale for x in re.split(r'[\s,]+', dash.strip())][:2]
                cut = []
                for poly in sp:
                    seg, left, drawing = [poly[0]], on, True
                    for a, b in zip(poly, poly[1:]):
                        L = math.hypot(b[0] - a[0], b[1] - a[1])
                        pos = 0
                        while L - pos > left:
                            pos += left
                            q = (a[0] + (b[0] - a[0]) * pos / L, a[1] + (b[1] - a[1]) * pos / L)
                            if drawing:
                                seg.append(q)
                                cut.append(seg)
                            seg = [q]
                            drawing = not drawing
                            left = on if drawing else off
                        left -= L - pos
                        if drawing:
                            seg.append(b)
                        else:
                            seg = [b]
                    if drawing and len(seg) > 1:
                        cut.append(seg)
                sp = cut
            parts.append({'d': [[c for q in poly for c in norm(q)] for poly in sp], 'f': 0,
                          'w': round(sw * scale / H, 4), 'c': argb(stroke, op * float(st.get('stroke-opacity', 1)))})

    def walk(el, st, m):
        tag = el.tag.split('}')[-1]
        if tag in ('defs', 'linearGradient', 'radialGradient', 'title'):
            return
        st = dict(st)
        for k in ('fill', 'stroke', 'stroke-width', 'opacity', 'fill-opacity', 'font-size', 'text-anchor', 'stroke-dasharray'):
            if el.get(k) is not None:
                if k == 'opacity':
                    st[k] = str(float(st.get(k, 1)) * float(el.get(k)))
                else:
                    st[k] = el.get(k)
        m = mat_mul(m, parse_tf(el.get('transform')))
        g = lambda k, d=0: float(el.get(k, d))
        if tag in ('svg', 'g'):
            for c in el:
                walk(c, st, m)
        elif tag == 'rect':
            rx = g('rx', el.get('ry', 0))
            ry = g('ry', el.get('rx', 0))
            emit_shape([rrect_pts(g('x'), g('y'), g('width'), g('height'), rx, ry)], st, m, True)
        elif tag == 'circle':
            emit_shape([ellipse_pts(g('cx'), g('cy'), g('r'), g('r'))], st, m, True)
        elif tag == 'ellipse':
            emit_shape([ellipse_pts(g('cx'), g('cy'), g('rx'), g('ry'))], st, m, True)
        elif tag == 'line':
            st.setdefault('stroke', '#000000')
            st2 = dict(st)
            st2['fill'] = 'none'
            emit_shape([[(g('x1'), g('y1')), (g('x2'), g('y2'))]], st2, m, False)
        elif tag in ('polygon', 'polyline'):
            nums = [float(x) for x in re.split(r'[\s,]+', el.get('points').strip()) if x]
            pts = list(zip(nums[0::2], nums[1::2]))
            if tag == 'polygon':
                pts.append(pts[0])
            emit_shape([pts], st, m, tag == 'polygon')
        elif tag == 'path':
            d = el.get('d')
            closed = 'z' in d.lower()
            emit_shape(path_polys(d), st, m, closed or st.get('fill', '#000') not in ('none',))
        elif tag == 'text':
            txt = ''.join(el.itertext()).strip()
            fs = float(st.get('font-size', 16))
            x, y = g('x'), g('y')
            anchor = st.get('text-anchor', 'start')
            if anchor == 'start':
                x += len(txt) * fs * 0.3
            elif anchor == 'end':
                x -= len(txt) * fs * 0.3
            cx, cy = apply(m, (x, y - fs * 0.36))
            fill = col(st.get('fill', '#000000'), defs) or '#000000'
            scale = math.sqrt(abs(m[0] * m[3] - m[1] * m[2]))
            parts.append({'t': txt, 'x': round((cx - ox) / W, 4), 'y': round((cy - oy) / H, 4),
                          's': round(fs * scale / H, 4), 'c': argb(fill, float(st.get('opacity', 1)))})

    walk(root, {}, (1, 0, 0, 1, 0, 0))
    parts = [p for p in parts if 't' in p or p['d']]
    return {'a': round(W / H, 4), 'p': parts}
