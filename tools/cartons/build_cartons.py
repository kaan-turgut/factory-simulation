"""Print artwork for the finished-good shipping cartons.

Writes one texture atlas per product to assets/cartons/<code>.png, plus generic.png for
pallets without a product. Brands, logos and illustrations are original; the fonts are
SIL Open Font Licence fonts from Google Fonts (tools/cartons/fonts, licences alongside).

Run from the project root:  python3 tools/cartons/build_cartons.py [preview.png]

Atlas layout (pixels, 1024 x 768). world/stock_models.gd maps the carton faces onto it,
so keep the two in step:
  FRONT  (0, 0, 1024, 472)   both long sides, 0.74 x 0.34 m
  END    (0, 476, 472, 292)  both short ends, 0.55 x 0.34 m
  TOP    (480, 476, 392, 292) top flaps with tape, 0.74 x 0.55 m
  BASE   (880, 476, 144, 292) plain board for the underside
"""
import json, math, os, random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FONTS = os.path.join(os.path.dirname(__file__), "fonts")
OUT = os.path.join(ROOT, "assets", "cartons")
S = 2  # supersampling
W, H = 1024, 768
FRONT = (0, 0, 1024, 472)
END = (0, 476, 472, 292)
TOP = (480, 476, 392, 292)
BASE = (880, 476, 144, 292)
KRAFT = (205, 160, 110)
WAFER = (226, 181, 116)
CREAM = (250, 244, 228)


def font(name, size, weight=None):
    f = ImageFont.truetype(os.path.join(FONTS, name), int(size * S))
    if weight is not None:
        try:
            f.set_variation_by_axes([weight] if "Oswald" in name else [weight, 100])
        except OSError:
            pass
    return f


def hexc(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def mix(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def dark(c, t):
    return mix(c, (0, 0, 0), t)


def light(c, t):
    return mix(c, (255, 255, 255), t)


def luminance(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


class Canvas:
    """Draws in panel-local units (atlas pixels), scaled by S."""

    def __init__(self, image, rect):
        self.image = image
        self.ox, self.oy, self.w, self.h = rect
        self.d = ImageDraw.Draw(image)

    def p(self, x, y):
        return ((self.ox + x) * S, (self.oy + y) * S)

    def box(self, x0, y0, x1, y1):
        a, b = self.p(x0, y0), self.p(x1, y1)
        return [a[0], a[1], b[0], b[1]]

    def rect(self, x0, y0, x1, y1, fill, radius=0, outline=None, width=0):
        if radius:
            self.d.rounded_rectangle(self.box(x0, y0, x1, y1), radius * S, fill=fill, outline=outline, width=width * S)
        else:
            self.d.rectangle(self.box(x0, y0, x1, y1), fill=fill, outline=outline, width=width * S)

    def ellipse(self, cx, cy, rx, ry, fill, outline=None, width=0):
        self.d.ellipse(self.box(cx - rx, cy - ry, cx + rx, cy + ry), fill=fill, outline=outline, width=int(width * S))

    def poly(self, points, fill, outline=None, width=0):
        pts = [self.p(x, y) for x, y in points]
        self.d.polygon(pts, fill=fill)
        if outline:
            self.d.line(pts + [pts[0]], fill=outline, width=int(width * S), joint="curve")

    def line(self, points, fill, width):
        self.d.line([self.p(x, y) for x, y in points], fill=fill, width=int(width * S), joint="curve")

    def text(self, x, y, value, f, fill, anchor="mm", stroke=0, stroke_fill=None, shadow=None):
        if shadow:
            sx, sy, sc = shadow
            self.d.text(self.p(x + sx, y + sy), value, font=f, fill=sc, anchor=anchor,
                stroke_width=int(stroke * S), stroke_fill=sc)
        self.d.text(self.p(x, y), value, font=f, fill=fill, anchor=anchor,
            stroke_width=int(stroke * S), stroke_fill=stroke_fill)

    def fit(self, value, name, size, max_width, weight=None):
        f = font(name, size, weight)
        while f.getlength(value) > max_width * S and size > 8:
            size -= 2
            f = font(name, size, weight)
        return f


# ---------------------------------------------------------------- illustrations

def wafer_bar(c, cx, cy, length, coat, filled=False, cream=None):
    """Coated wafer finger in three-quarter view, with ridges and a broken end."""
    h = length * 0.26
    d = length * 0.16
    x0, x1 = cx - length / 2, cx + length / 2
    c.poly([(x0 + d, cy - h / 2 - d), (x1 + d, cy - h / 2 - d), (x1, cy - h / 2), (x0, cy - h / 2)], light(coat, 0.18))
    c.poly([(x1, cy - h / 2), (x1 + d, cy - h / 2 - d), (x1 + d, cy + h / 2 - d), (x1, cy + h / 2)], dark(coat, 0.3))
    c.rect(x0, cy - h / 2, x1, cy + h / 2, coat)
    for i in range(1, 7):
        x = x0 + i * length / 7
        c.line([(x, cy - h / 2 + 3), (x, cy + h / 2 - 3)], dark(coat, 0.18), 3)
    for i in range(1, 7):
        x = x0 + i * length / 7 + 3
        c.line([(x, cy - h / 2 + 3), (x, cy + h / 2 - 3)], light(coat, 0.15), 1.5)
    # Broken end shows the wafer (and cream) inside.
    bx = x0
    c.poly([(bx - 2, cy - h / 2), (bx + 14, cy - h / 2), (bx + 6, cy), (bx + 16, cy + h / 2), (bx - 2, cy + h / 2)], WAFER)
    layers = 5 if filled else 3
    for i in range(1, layers):
        y = cy - h / 2 + i * h / layers
        col = cream if filled and i % 2 == 1 else dark(WAFER, 0.25)
        c.line([(bx, y), (bx + 10, y)], col, 4 if filled else 2)


def drip(c, x0, x1, y, col, rng):
    """Chocolate drip edge hanging from y."""
    pts = [(x0, y - 20), (x1, y - 20), (x1, y)]
    x = x1
    while x > x0:
        step = rng.uniform(26, 48)
        depth = rng.uniform(8, 30)
        pts += [(x - step * 0.2, y + depth * 0.6), (x - step * 0.5, y + depth), (x - step * 0.8, y + depth * 0.6), (x - step, y)]
        x -= step
    pts.append((x0, y))
    c.poly(pts, col)


def hazelnut(c, cx, cy, r):
    c.ellipse(cx, cy + r * 0.15, r * 0.85, r, (150, 92, 48))
    c.ellipse(cx - r * 0.25, cy + r * 0.05, r * 0.25, r * 0.55, (176, 116, 66))
    c.ellipse(cx, cy - r * 0.75, r * 0.6, r * 0.32, (112, 70, 38))
    c.ellipse(cx, cy - r * 0.82, r * 0.5, r * 0.18, (90, 56, 30))


def strawberry(c, cx, cy, r, face=False):
    c.poly([(cx - r, cy - r * 0.45), (cx - r * 0.75, cy - r * 0.9), (cx, cy - r * 0.8), (cx + r * 0.75, cy - r * 0.9),
        (cx + r, cy - r * 0.45), (cx + r * 0.6, cy + r * 0.55), (cx, cy + r * 1.05), (cx - r * 0.6, cy + r * 0.55)], (214, 40, 58))
    c.ellipse(cx - r * 0.35, cy - r * 0.35, r * 0.22, r * 0.14, (238, 110, 120))
    rng = random.Random(3)
    if not face:
        for _ in range(14):
            x = cx + rng.uniform(-0.65, 0.65) * r
            y = cy + rng.uniform(-0.5, 0.6) * r
            if abs(x - cx) < r * (0.9 - 0.6 * max(0, (y - cy) / r)):
                c.ellipse(x, y, r * 0.05, r * 0.08, (255, 214, 120))
    for a in (-0.9, -0.45, 0, 0.45, 0.9):
        c.poly([(cx, cy - r * 0.8), (cx + math.sin(a) * r * 0.75, cy - r * 0.8 - math.cos(a) * r * 0.45),
            (cx + math.sin(a) * r * 0.2, cy - r * 0.7)], (60, 150, 60))
    if face:
        smiley(c, cx, cy + r * 0.05, r * 0.7)


def orange(c, cx, cy, r, face=False):
    c.ellipse(cx, cy, r, r, (242, 136, 30))
    c.ellipse(cx - r * 0.35, cy - r * 0.35, r * 0.25, r * 0.18, (250, 184, 92))
    c.poly([(cx, cy - r * 0.95), (cx + r * 0.55, cy - r * 1.35), (cx + r * 0.8, cy - r * 1.1), (cx + r * 0.2, cy - r * 0.9)], (70, 150, 60))
    if face:
        smiley(c, cx, cy + r * 0.05, r * 0.7)


def apple(c, cx, cy, r, face=False):
    c.ellipse(cx - r * 0.42, cy, r * 0.62, r * 0.85, (112, 190, 60))
    c.ellipse(cx + r * 0.42, cy, r * 0.62, r * 0.85, (112, 190, 60))
    c.ellipse(cx, cy + r * 0.1, r * 0.75, r * 0.8, (112, 190, 60))
    c.ellipse(cx - r * 0.45, cy - r * 0.35, r * 0.2, r * 0.15, (178, 226, 130))
    c.line([(cx, cy - r * 0.65), (cx + r * 0.1, cy - r * 1.1)], (100, 66, 40), r * 0.12)
    c.poly([(cx + r * 0.1, cy - r * 0.95), (cx + r * 0.6, cy - r * 1.2), (cx + r * 0.3, cy - r * 0.85)], (50, 130, 50))
    if face:
        smiley(c, cx, cy + r * 0.1, r * 0.7)


def smiley(c, cx, cy, r):
    for s in (-1, 1):
        c.ellipse(cx + s * r * 0.35, cy - r * 0.15, r * 0.16, r * 0.2, (255, 255, 255))
        c.ellipse(cx + s * r * 0.35 + r * 0.04, cy - r * 0.12, r * 0.08, r * 0.11, (30, 30, 40))
        c.ellipse(cx + s * r * 0.62, cy + r * 0.2, r * 0.13, r * 0.08, (255, 150, 160))
    c.d.arc(c.box(cx - r * 0.3, cy - r * 0.05, cx + r * 0.3, cy + r * 0.45), 20, 160, fill=(40, 30, 40), width=int(r * 0.1 * S))


def leaf(c, cx, cy, r, angle, col):
    pts = []
    for i in range(21):
        t = i / 20
        x = (t - 0.5) * 2 * r
        y = math.sin(t * math.pi) * r * 0.42
        pts.append((x, y))
    for i in range(20, -1, -1):
        t = i / 20
        pts.append(((t - 0.5) * 2 * r, -math.sin(t * math.pi) * r * 0.42))
    ca, sa = math.cos(angle), math.sin(angle)
    c.poly([(cx + x * ca - y * sa, cy + x * sa + y * ca) for x, y in pts], col)
    c.line([(cx - r * ca, cy - r * sa), (cx + r * ca * 0.9, cy + r * sa * 0.9)], dark(col, 0.25), r * 0.06)
    for k in (-0.4, 0.0, 0.4):
        bx, by = cx + k * r * ca, cy + k * r * sa
        for s in (-1, 1):
            c.line([(bx, by), (bx + (0.3 * ca - s * 0.25 * sa) * r, by + (0.3 * sa + s * 0.25 * ca) * r)], dark(col, 0.2), r * 0.035)


def snowflake(c, cx, cy, r, col):
    for k in range(6):
        a = k * math.pi / 3
        ex, ey = cx + math.cos(a) * r, cy + math.sin(a) * r
        c.line([(cx, cy), (ex, ey)], col, r * 0.12)
        for t in (0.55, 0.8):
            bx, by = cx + math.cos(a) * r * t, cy + math.sin(a) * r * t
            for s in (-1, 1):
                b = a + s * 0.8
                c.line([(bx, by), (bx + math.cos(b) * r * 0.25, by + math.sin(b) * r * 0.25)], col, r * 0.09)


def cocoa_bean(c, cx, cy, r):
    c.ellipse(cx, cy, r * 0.62, r, (98, 52, 36))
    c.ellipse(cx - r * 0.15, cy - r * 0.2, r * 0.18, r * 0.45, (130, 76, 54))
    c.line([(cx, cy - r * 0.85), (cx + r * 0.08, cy), (cx, cy + r * 0.85)], (70, 36, 26), r * 0.1)


def milk_splash(c, cx, cy, r, col=(255, 255, 255)):
    c.ellipse(cx, cy + r * 0.2, r * 1.05, r * 0.6, (200, 212, 232))
    c.ellipse(cx, cy + r * 0.2, r, r * 0.55, col)
    rng = random.Random(11)
    for k in range(7):
        a = math.pi + k * math.pi / 6
        x, y = cx + math.cos(a) * r * 0.9, cy + r * 0.1 + math.sin(a) * r * 0.5
        c.poly([(x - r * 0.12, y + r * 0.1), (x + math.cos(a) * r * 0.35, y + math.sin(a) * r * rng.uniform(0.5, 0.9)), (x + r * 0.12, y + r * 0.1)], col)
        c.ellipse(x + math.cos(a) * r * 0.4, y + math.sin(a) * r * 1.0, r * 0.08, r * 0.08, col)


def vanilla_flower(c, cx, cy, r):
    for k in range(5):
        a = -math.pi / 2 + k * 2 * math.pi / 5
        c.ellipse(cx + math.cos(a) * r * 0.5, cy + math.sin(a) * r * 0.5, r * 0.42, r * 0.42, (252, 246, 214))
    c.ellipse(cx, cy, r * 0.28, r * 0.28, (240, 196, 70))
    for k in range(2):
        c.line([(cx - r * 1.4 + k * 18, cy + r * 1.3), (cx - r * 0.2 + k * 18, cy + r * 0.6)], (70, 46, 30), r * 0.12)


def bottle(c, cx, cy, h, body, cap):
    w = h * 0.55
    c.rect(cx - w / 2, cy - h / 2 + h * 0.18, cx + w / 2, cy + h / 2, body, radius=w * 0.18)
    c.rect(cx - w * 0.42, cy - h / 2, cx + w * 0.42, cy - h / 2 + h * 0.22, cap, radius=w * 0.08)
    for k in range(5):
        x = cx - w * 0.36 + k * w * 0.18
        c.line([(x, cy - h / 2 + 4), (x, cy - h / 2 + h * 0.2)], dark(cap, 0.2), 2)
    c.rect(cx - w / 2, cy - h * 0.05, cx + w / 2, cy + h * 0.3, (255, 255, 255))
    c.rect(cx - w * 0.38, cy + h * 0.32, cx - w * 0.28, cy + h * 0.46, light(body, 0.4))


def watermelon(c, cx, cy, r):
    c.d.pieslice(c.box(cx - r, cy - r, cx + r, cy + r), 0, 180, fill=(60, 140, 60))
    c.d.pieslice(c.box(cx - r * 0.9, cy - r * 0.9, cx + r * 0.9, cy + r * 0.9), 0, 180, fill=(240, 240, 220))
    c.d.pieslice(c.box(cx - r * 0.82, cy - r * 0.82, cx + r * 0.82, cy + r * 0.82), 0, 180, fill=(236, 74, 92))
    for k in range(7):
        a = 0.35 + k * 0.4
        c.ellipse(cx + math.cos(a) * r * 0.5, cy + math.sin(a) * r * 0.5, r * 0.05, r * 0.09, (40, 30, 30))


def gum_pellets(c, cx, cy, r, col, n=5):
    rng = random.Random(5)
    for k in range(n):
        x = cx + (k - n / 2) * r * 0.9 + rng.uniform(-4, 4)
        y = cy + rng.uniform(-r * 0.4, r * 0.4)
        c.ellipse(x, y, r * 0.55, r * 0.38, dark(col, 0.08))
        c.ellipse(x - r * 0.05, y - r * 0.06, r * 0.5, r * 0.32, col)
        c.ellipse(x - r * 0.2, y - r * 0.14, r * 0.15, r * 0.08, (255, 255, 255))


# ---------------------------------------------------------------- shared print

def barcode(c, x, y, w, h, seed):
    rng = random.Random(seed)
    c.rect(x - 6, y - 6, x + w + 6, y + h + 18, (255, 255, 255))
    pos = x
    while pos < x + w - 3:
        bar = rng.choice((1.5, 1.5, 3, 4.5))
        c.rect(pos, y, pos + bar, y + h, (20, 20, 20))
        pos += bar + rng.choice((1.5, 3, 3, 4.5))
    digits = "".join(str(rng.randint(0, 9)) for _ in range(13))
    c.text(x + w / 2, y + h + 8, digits, font("Oswald[wght].ttf", 11, 400), (20, 20, 20))


def handling_marks(c, x, y, col):
    # "This way up" arrows and "keep dry" umbrella, in a frame.
    c.rect(x, y, x + 96, y + 52, None, outline=col, width=2)
    for k in (0, 1):
        ax = x + 16 + k * 18
        c.line([(ax, y + 44), (ax, y + 14)], col, 4)
        c.poly([(ax - 8, y + 18), (ax, y + 6), (ax + 8, y + 18)], col)
    ux, uy = x + 72, y + 22
    c.d.pieslice(c.box(ux - 16, uy - 14, ux + 16, uy + 14), 180, 360, fill=col)
    c.line([(ux, uy), (ux, uy + 20), (ux - 6, uy + 22)], col, 3)


def board_finish(image):
    """Corrugated board: flute shading, slight print wear and darker panel edges."""
    w, h = image.size
    shade = Image.new("L", (w, h), 255)
    sd = ImageDraw.Draw(shade)
    period = 9 * S
    for x in range(0, w, period):
        sd.rectangle([x, 0, x + period // 3, h], fill=244)
    rng = random.Random(1)
    for _ in range(900):
        x, y = rng.randrange(w), rng.randrange(h)
        sd.ellipse([x, y, x + rng.randint(2, 7) * S, y + rng.randint(1, 3) * S], fill=rng.randint(226, 240))
    for rect in (FRONT, END, TOP, BASE):
        x0, y0, rw, rh = [v * S for v in rect]
        for k in range(10 * S):
            v = int(205 + 50 * (k / (10 * S)) ** 0.6)
            sd.rectangle([x0 + k, y0 + k, x0 + rw - 1 - k, y0 + rh - 1 - k], outline=v)
    shade = shade.filter(ImageFilter.GaussianBlur(1.2 * S))
    r, g, b = image.split()
    from PIL import ImageChops
    return Image.merge("RGB", [ImageChops.multiply(ch, shade) for ch in (r, g, b)])


def kraft_panel(c, fill=KRAFT):
    c.rect(0, 0, c.w, c.h, fill)


def top_panel(c, brand_col, mark):
    """Kraft flaps meeting along the centre, brown tape over the seam, a printed mark."""
    kraft_panel(c)
    c.line([(0, c.h / 2), (c.w, c.h / 2)], dark(KRAFT, 0.35), 2)
    c.rect(c.w / 2 - 24, 0, c.w / 2 + 24, c.h, (198, 162, 108))
    c.rect(c.w / 2 - 24, 0, c.w / 2 - 21, c.h, (176, 140, 90))
    c.rect(c.w / 2 + 21, 0, c.w / 2 + 24, c.h, (176, 140, 90))
    c.text(c.w * 0.24, c.h * 0.26, mark, c.fit(mark, "Oswald[wght].ttf", 34, c.w * 0.36, 600), brand_col)
    c.text(c.w * 0.76, c.h * 0.74, mark, c.fit(mark, "Oswald[wght].ttf", 34, c.w * 0.36, 600), brand_col)
    for k in (0, 1):
        ax = c.w * 0.24 - 14 + k * 28
        c.line([(ax, c.h * 0.74 + 16), (ax, c.h * 0.74 - 10)], brand_col, 4)
        c.poly([(ax - 8, c.h * 0.74 - 6), (ax, c.h * 0.74 - 18), (ax + 8, c.h * 0.74 - 6)], brand_col)


# ---------------------------------------------------------------- brands

def info_strip(c, product, color, text_col, seed, x0=0):
    """White band along the bottom: pack count, code and a barcode."""
    y = c.h - 86
    c.rect(x0, y, c.w, c.h, (250, 248, 242))
    c.rect(x0, y, c.w, y + 6, color)
    packs = "%d × %d g" % (product["packs_per_box"], round(product["pack_kg"] * 1000))
    c.text(x0 + 26, y + 46, packs, font("Oswald[wght].ttf", 34, 600), text_col, anchor="lm")
    c.text(x0 + 300, y + 46, product["code"], font("Oswald[wght].ttf", 28, 500), dark(text_col, 0.1), anchor="lm")
    barcode(c, c.w - 250, y + 18, 210, 40, seed)


def crispella(c, p, name, flavour, icon, rng):
    col = hexc(p["package_color"])
    coat = hexc(p["coating_color"])
    kraft_panel(c, col)
    # Diagonal light band behind the product and a coating drip along the top.
    c.poly([(c.w * 0.52, 0), (c.w, 0), (c.w, c.h), (c.w * 0.38, c.h)], light(col, 0.18))
    drip(c, 0, c.w, 34, coat if luminance(coat) < 200 else light(coat, 0.3), rng)
    if luminance(coat) > 200:
        drip(c, 0, c.w, 26, dark(coat, 0.06), random.Random(2))
    # Logo: script wordmark on a cream ribbon with a gold rule.
    c.rect(36, 82, 500, 210, CREAM, radius=60)
    c.rect(48, 92, 488, 200, None, radius=52, outline=(196, 156, 70), width=3)
    c.text(268, 140, "Crispella", font("Pacifico-Regular.ttf", 74), dark(col, 0.45), shadow=(3, 4, light(col, 0.4)))
    c.text(268, 236, flavour.upper(), c.fit(flavour.upper(), "Oswald[wght].ttf", 52, 460, 700),
        CREAM, stroke=2, stroke_fill=dark(col, 0.4))
    c.text(268, 290, "CHOCOLATE WAFER", font("Oswald[wght].ttf", 26, 500), light(col, 0.7))
    wafer_bar(c, 760, 245, 330, coat)
    wafer_bar(c, 700, 330, 290, coat)
    icon(c, 930, 140, 54)
    info_strip(c, p, dark(col, 0.2), dark(col, 0.55), p["code"])


def velvetto(c, p, name, flavour, icon, rng):
    col = hexc(p["package_color"])
    coat = hexc(p["coating_color"])
    kraft_panel(c, dark(col, 0.15))
    # Soft cream wave across the panel.
    pts = [(0, c.h)]
    for i in range(41):
        x = i * c.w / 40
        pts.append((x, 250 + 30 * math.sin(i / 40 * math.pi * 2.2)))
    pts.append((c.w, c.h))
    c.poly(pts, light(col, 0.82))
    c.text(220, 104, "Velvetto", font("Lobster-Regular.ttf", 96), (255, 250, 236),
        stroke=3, stroke_fill=dark(col, 0.45), shadow=(4, 5, dark(col, 0.55)))
    c.line([(70, 166), (370, 166)], (226, 190, 110), 4)
    c.text(220, 196, "CREAM WAFERS", font("Oswald[wght].ttf", 26, 500), (255, 240, 210))
    c.text(220, 300, flavour, c.fit(flavour, "Lobster-Regular.ttf", 54, 400), dark(col, 0.45))
    # Layered wafer cross-section: wafer and cream, coated on top when coated.
    x0, x1, y0 = 520, 940, 190
    cream = light(coat, 0.7) if p["coating"] != "None" else (250, 238, 200)
    layers = [WAFER, cream, WAFER, cream, WAFER]
    for i, lc in enumerate(layers):
        hgt = 26 if lc == WAFER else 20
        y = y0 + sum(26 if l == WAFER else 20 for l in layers[:i])
        c.rect(x0, y, x1, y + hgt, lc)
        if lc == WAFER:
            for gx in range(int(x0) + 12, int(x1), 24):
                c.line([(gx, y + 4), (gx, y + hgt - 4)], dark(WAFER, 0.15), 2)
    if p["coating"] != "None":
        c.rect(x0 - 6, y0 - 26, x1 + 6, y0 + 4, coat, radius=10)
        c.rect(x0 - 6, y0 + 108, x1 + 6, y0 + 124, coat, radius=6)
    icon(c, 930, 120, 50)
    info_strip(c, p, dark(col, 0.1), dark(col, 0.55), p["code"])


def velvetto_bites(c, p, name, flavour, icon, rng):
    col = hexc(p["package_color"])
    kraft_panel(c, col)
    for i in range(9):
        c.ellipse(rng.uniform(0, c.w), rng.uniform(0, c.h - 90), 40, 40, light(col, 0.12))
    c.text(210, 100, "Velvetto", font("Lobster-Regular.ttf", 80), (255, 250, 236),
        stroke=3, stroke_fill=dark(col, 0.45), shadow=(4, 5, dark(col, 0.5)))
    c.rect(150, 160, 420, 250, (70, 40, 26), radius=18)
    c.text(285, 205, "MINI BITES", font("Bebas Neue".replace(" ", "") + "-Regular.ttf", 74), (255, 214, 120))
    c.text(285, 300, "Hazelnut cream", font("Lobster-Regular.ttf", 44), dark(col, 0.5))
    for k, (x, y) in enumerate([(600, 210), (700, 180), (800, 225), (650, 300), (760, 310)]):
        c.rect(x - 44, y - 30, x + 44, y + 30, WAFER, radius=8)
        for gx in range(x - 36, x + 40, 14):
            c.line([(gx, y - 24), (gx, y + 24)], dark(WAFER, 0.15), 2)
        c.rect(x - 44, y - 4, x + 44, y + 6, (176, 120, 72))
    hazelnut(c, 920, 170, 60)
    hazelnut(c, 890, 300, 42)
    info_strip(c, p, dark(col, 0.2), dark(col, 0.55), p["code"])


def frostline(c, p, name, flavour, icon, rng):
    col = hexc(p["package_color"])
    kraft_panel(c, dark(col, 0.35))
    # Icy diagonal stripes.
    for i in range(-4, 12):
        x = i * 110
        c.poly([(x, 0), (x + 40, 0), (x - 140, c.h), (x - 180, c.h)], dark(col, 0.25))
    c.rect(0, 70, 620, 230, col)
    c.rect(0, 222, 620, 230, (255, 255, 255))
    snowflake(c, 80, 150, 56, (255, 255, 255))
    c.text(150, 154, "FROSTLINE", font("BebasNeue-Regular.ttf", 128), (255, 255, 255), anchor="lm",
        shadow=(4, 4, dark(col, 0.45)))
    c.text(40, 286, flavour.upper(), c.fit(flavour.upper(), "BebasNeue-Regular.ttf", 70, 560), light(col, 0.75), anchor="lm")
    c.rect(40, 324, 250, 362, (255, 255, 255), radius=19)
    c.text(145, 344, "SUGAR-FREE", font("Oswald[wght].ttf", 24, 700), dark(col, 0.3))
    # Gum wallet with pellets.
    c.rect(680, 110, 960, 330, light(col, 0.85), radius=18)
    c.rect(680, 110, 960, 160, col, radius=18)
    c.rect(680, 140, 960, 160, col)
    c.text(820, 136, "FROSTLINE", font("BebasNeue-Regular.ttf", 40), (255, 255, 255))
    gum_pellets(c, 830, 240, 34, (246, 250, 248), 4)
    icon(c, 960, 70, 50)
    info_strip(c, p, col, dark(col, 0.55), p["code"])


def xylo(c, p, name, flavour, icon, rng):
    col = hexc(p["package_color"])
    kraft_panel(c, (246, 248, 250))
    c.rect(0, 0, c.w, 60, col)
    c.ellipse(170, 170, 120, 120, col)
    c.ellipse(170, 170, 98, 98, (255, 255, 255))
    c.text(170, 166, "XYLO", font("Righteous-Regular.ttf", 72), col)
    c.text(170, 316, "100% XYLITOL", font("Oswald[wght].ttf", 26, 600), dark(col, 0.4))
    c.text(330, 150, flavour, c.fit(flavour, "Righteous-Regular.ttf", 64, 360), dark(col, 0.35), anchor="lm")
    c.text(330, 220, "CHEWING GUM · BOTTLE", font("Oswald[wght].ttf", 24, 500), (110, 120, 130), anchor="lm")
    bottle(c, 790, 240, 250, col, dark(col, 0.35))
    bottle(c, 915, 260, 200, col, dark(col, 0.35))
    icon(c, 640, 290, 60)
    info_strip(c, p, col, dark(col, 0.55), p["code"])


def fruity(c, p, name, flavour, icon, rng):
    col = hexc(p["package_color"])
    kraft_panel(c, light(col, 0.15))
    for i in range(16):
        c.ellipse(rng.uniform(0, c.w), rng.uniform(0, c.h - 90), rng.uniform(8, 22), rng.uniform(8, 22), light(col, 0.45))
    # Bubbly two-line wordmark with a white outline.
    f = font("Fredoka[wdth,wght].ttf", 84, 700)
    c.text(250, 112, "Fruity", f, (255, 255, 255), stroke=10, stroke_fill=dark(col, 0.5))
    c.text(250, 112, "Fruity", f, (255, 214, 64))
    c.text(270, 200, "Friends", f, (255, 255, 255), stroke=10, stroke_fill=dark(col, 0.5))
    c.text(270, 200, "Friends", f, (110, 200, 255))
    c.rect(110, 262, 430, 330, (255, 255, 255), radius=34)
    c.text(270, 296, flavour.upper(), c.fit(flavour.upper(), "Fredoka[wdth,wght].ttf", 40, 290, 700), dark(col, 0.25))
    icon(c, 740, 210, 120)
    gum_pellets(c, 920, 320, 22, light(col, 0.3), 3)
    info_strip(c, p, dark(col, 0.1), dark(col, 0.6), p["code"])


# code: (brand, flavour, front icon, end icon, top mark)
PRODUCTS = {
    "FG-1001": (crispella, "Classic Milk", lambda c, x, y, r: milk_splash(c, x, y, r), "CRISPELLA"),
    "FG-1002": (crispella, "Dark 55%", lambda c, x, y, r: cocoa_bean(c, x, y, r), "CRISPELLA"),
    "FG-1003": (crispella, "White", lambda c, x, y, r: vanilla_flower(c, x, y, r * 0.8), "CRISPELLA"),
    "FG-1004": (crispella, "Hazelnut", lambda c, x, y, r: hazelnut(c, x, y, r * 0.85), "CRISPELLA"),
    "FG-1005": (crispella, "Strawberry", lambda c, x, y, r: strawberry(c, x, y, r * 0.8), "CRISPELLA"),
    "FG-2001": (velvetto, "Milk & Vanilla", lambda c, x, y, r: vanilla_flower(c, x, y, r * 0.8), "VELVETTO"),
    "FG-2002": (velvetto, "Dark & Hazelnut", lambda c, x, y, r: hazelnut(c, x, y, r * 0.85), "VELVETTO"),
    "FG-2003": (velvetto, "White & Cocoa", lambda c, x, y, r: cocoa_bean(c, x, y, r), "VELVETTO"),
    "FG-2004": (velvetto, "Pure Vanilla", lambda c, x, y, r: vanilla_flower(c, x, y, r * 0.8), "VELVETTO"),
    "FG-2005": (velvetto_bites, "Hazelnut Bites", lambda c, x, y, r: hazelnut(c, x, y, r * 0.85), "VELVETTO"),
    "FG-3001": (frostline, "Fresh Spearmint", lambda c, x, y, r: leaf(c, x, y, r, -0.6, (120, 214, 140)), "FROSTLINE"),
    "FG-3002": (frostline, "Intense Peppermint", lambda c, x, y, r: snowflake(c, x, y, r * 0.8, (210, 236, 255)), "FROSTLINE"),
    "FG-3003": (xylo, "Peppermint", lambda c, x, y, r: leaf(c, x, y, r, -0.6, (90, 190, 120)), "XYLO"),
    "FG-3004": (xylo, "Watermelon", lambda c, x, y, r: watermelon(c, x, y - r * 0.3, r), "XYLO"),
    "FG-3005": (fruity, "Strawberry", lambda c, x, y, r: strawberry(c, x, y, r * 0.8, True), "FRUITY FRIENDS"),
    "FG-3006": (fruity, "Orange", lambda c, x, y, r: orange(c, x, y, r * 0.8, True), "FRUITY FRIENDS"),
    "FG-3007": (fruity, "Green Apple", lambda c, x, y, r: apple(c, x, y, r * 0.8, True), "FRUITY FRIENDS"),
}


def end_panel(c, p, flavour, icon, mark):
    col = hexc(p["package_color"])
    c.rect(0, 0, c.w, c.h, col)
    c.rect(0, 0, c.w, 54, dark(col, 0.35))
    c.text(c.w / 2, 28, mark, c.fit(mark, "Oswald[wght].ttf", 34, c.w - 40, 700), (255, 255, 255))
    c.ellipse(120, 150, 78, 78, (255, 255, 255))
    icon(c, 120, 150, 52)
    c.text(330, 112, flavour, c.fit(flavour, "Oswald[wght].ttf", 38, 250, 600),
        (255, 255, 255) if luminance(col) < 170 else dark(col, 0.6))
    c.text(330, 160, p["code"], font("Oswald[wght].ttf", 30, 500),
        light(col, 0.75) if luminance(col) < 170 else dark(col, 0.5))
    # Shipping label.
    c.rect(214, 192, 456, 280, (252, 250, 244))
    c.text(226, 208, "%d × %d g" % (p["packs_per_box"], round(p["pack_kg"] * 1000)), font("Oswald[wght].ttf", 20, 600), (30, 30, 30), anchor="lm")
    barcode(c, 228, 224, 150, 30, p["code"] + "end")
    handling_marks(c, 18, 226, (255, 255, 255) if luminance(col) < 170 else dark(col, 0.6))


def build(code, product, out):
    image = Image.new("RGB", (W * S, H * S), KRAFT)
    brand, flavour, icon, mark = PRODUCTS[code]
    rng = random.Random(code)
    brand(Canvas(image, FRONT), product, code, flavour, icon, rng)
    end_panel(Canvas(image, END), product, flavour, icon, mark)
    top_panel(Canvas(image, TOP), dark(hexc(product["package_color"]), 0.25), mark)
    kraft_panel(Canvas(image, BASE))
    image = board_finish(image).resize((W, H), Image.LANCZOS)
    image.save(out, optimize=True)
    return image


def build_generic(out):
    """Plain kraft carton with tape and a white shipping label, for pallets without a product."""
    image = Image.new("RGB", (W * S, H * S), KRAFT)
    c = Canvas(image, FRONT)
    kraft_panel(c)
    c.rect(560, 150, 900, 330, (244, 238, 220))
    c.rect(600, 250, 820, 280, (42, 42, 42))
    for k in range(3):
        c.rect(590, 180 + k * 20, 860 - k * 60, 190 + k * 20, (120, 120, 120))
    c = Canvas(image, END)
    kraft_panel(c)
    handling_marks(c, 30, 30, (80, 60, 40))
    top_panel(Canvas(image, TOP), (120, 90, 60), "")
    kraft_panel(Canvas(image, BASE))
    image = board_finish(image).resize((W, H), Image.LANCZOS)
    image.save(out, optimize=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(ROOT, "master_data", "products.json")) as f:
        data = json.load(f)
    products = data if isinstance(data, list) else next(iter(data.values()))
    by_code = {p["code"]: p for p in products}
    missing = [code for code in by_code if code not in PRODUCTS]
    if missing:
        sys.exit("No carton design for: " + ", ".join(missing))
    shots = []
    for code in sorted(PRODUCTS):
        shots.append(build(code, by_code[code], os.path.join(OUT, code + ".png")))
    build_generic(os.path.join(OUT, "generic.png"))
    if len(sys.argv) > 1:
        cols = 3
        tw, th = W // 2, H // 2
        sheet = Image.new("RGB", (tw * cols, th * math.ceil(len(shots) / cols)), (40, 40, 40))
        for i, shot in enumerate(shots):
            sheet.paste(shot.resize((tw, th)), ((i % cols) * tw, (i // cols) * th))
        sheet.save(sys.argv[1])
    print("Wrote %d carton atlases to %s" % (len(shots) + 1, OUT))


if __name__ == "__main__":
    main()
