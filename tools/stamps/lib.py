# Registry + small templates for the realistic stamps.
STAMPS = []
PACKS = {}  # id -> (zh, en, kind)


def pack(pid, zh, en, kind):
    PACKS[pid] = (zh, en, kind)


def S(sid, pk, zh, en, body, w=140, h=140, ed=False):
    STAMPS.append(dict(id=sid, pack=pk, zh=zh, en=en, ed=ed,
                       svg=f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}">{body}</svg>'))


HW = 'font-family="Arial Narrow,Arial,sans-serif" font-weight="700" text-anchor="middle"'


def T(x, y, s, txt, fill='#111'):
    return f'<text x="{x}" y="{y}" font-size="{s}" fill="{fill}" {HW}>{txt}</text>'


def warn(inner, bg='#ffcd00'):
    return f'<polygon points="70,4 136,70 70,136 4,70" fill="#111"/><polygon points="70,9 131,70 70,131 9,70" fill="{bg}"/>{inner}'


def regsq(inner, h=124):
    return f'<rect x="8" y="{(140-h)/2}" width="124" height="{h}" rx="8" fill="#fff" stroke="#111" stroke-width="3"/>{inner}'


def nosign(inner):
    return regsq(inner + '<circle cx="70" cy="70" r="50" fill="none" stroke="#c8102e" stroke-width="9"/><line x1="35" y1="35" x2="105" y2="105" stroke="#c8102e" stroke-width="9"/>')


def leads(xs, y1, y2):
    return ''.join(f'<line x1="{x}" y1="{y1}" x2="{x}" y2="{y2}" stroke="#9a9a9a" stroke-width="4"/>' for x in xs)


def plate(color='#f3ead6', edge='#cbbf9f'):
    return f'<rect x="34" y="6" width="72" height="128" rx="6" fill="{color}" stroke="{edge}" stroke-width="2"/>'


def socket(y, face='#efe4cb', edge='#bcae8a'):
    return (f'<rect x="44" y="{y}" width="52" height="44" rx="14" fill="{face}" stroke="{edge}"/>'
            f'<rect x="56" y="{y+8}" width="5" height="16" fill="#333"/><rect x="78" y="{y+8}" width="5" height="20" fill="#333"/>'
            f'<path d="M66 {y+32} a4 4 0 0 1 8 0 v6 h-8z" fill="#333"/>')


def tile(txt, bg='#4dabf7', fg='#fff', s=56):
    return f'<rect x="10" y="10" width="120" height="120" rx="24" fill="{bg}"/>' + T(70, 70 + s * 0.36, s, txt, fg)


def weather_cloud(x=0, y=0, c='#cfd8e3'):
    return (f'<g transform="translate({x} {y})"><ellipse cx="70" cy="74" rx="44" ry="22" fill="{c}"/>'
            f'<circle cx="54" cy="62" r="20" fill="{c}"/><circle cx="80" cy="54" r="24" fill="{c}"/></g>')
