# Realistic stamps (source)

Each stamp is drawn as a small SVG in `s_work.py` (electrician, US traffic), `s_sci.py`
(math, physics, chemistry, biology) and `s_more.py` (medicine, genetics, AI, earth &
space, art, music). Names are Chinese + English only.

Build (needs `pip install svg.path`):

    python3 build.py s_work,s_sci,s_more

It writes `packages/ink/lib/src/packs/real.g.dart` and `preview.html` (open it to check).
`conv.py` turns the SVG subset (rect, circle, ellipse, line, polyline, polygon, path,
text, g with transforms, solid colours / gradients as their middle colour, dashes) into
stamp parts.
