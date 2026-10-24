# Renders the app icon: a glowing remote on a deep indigo gradient.
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # draw at 2x, downsample for smooth edges
out = sys.argv[1]

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

bg = Image.new("RGB", (S, S))
top, bottom = (58, 28, 140), (12, 10, 36)
px = bg.load()
for y in range(S):
    row = lerp(top, bottom, y / S)
    for x in range(S):
        px[x, y] = row

# Soft glow behind the remote
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).ellipse((S*0.18, S*0.12, S*0.82, S*0.88), fill=170)
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.09))
bg.paste(Image.new("RGB", (S, S), (140, 90, 255)), (0, 0), glow)

d = ImageDraw.Draw(bg)
# Remote body
bx0, by0, bx1, by1 = S*0.31, S*0.12, S*0.69, S*0.90
d.rounded_rectangle((bx0, by0, bx1, by1), radius=S*0.17, fill=(24, 22, 44), outline=(120, 100, 220), width=int(S*0.012))
cx = S / 2
# Power button
d.ellipse((cx - S*0.045, S*0.19, cx + S*0.045, S*0.28), fill=(255, 84, 112))
# D-pad ring and OK button
r = S * 0.135
cy = S * 0.45
d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(52, 46, 92))
for ax, ay in ((0, -1), (0, 1), (-1, 0), (1, 0)):
    tx, ty = cx + ax * r * 0.72, cy + ay * r * 0.72
    w = S * 0.028
    if ax == 0:
        pts = [(tx - w, ty - ay * w * 0.6), (tx + w, ty - ay * w * 0.6), (tx, ty + ay * w)]
    else:
        pts = [(tx - ax * w * 0.6, ty - w), (tx - ax * w * 0.6, ty + w), (tx + ax * w, ty)]
    d.polygon(pts, fill=(200, 190, 255))
ok = S * 0.06
d.ellipse((cx - ok, cy - ok, cx + ok, cy + ok), fill=(150, 110, 255))
# Volume / channel rockers
for x in (cx - S*0.085, cx + S*0.085):
    d.rounded_rectangle((x - S*0.04, S*0.64, x + S*0.04, S*0.82), radius=S*0.04, fill=(52, 46, 92))

bg.resize((1024, 1024), Image.LANCZOS).save(out)
