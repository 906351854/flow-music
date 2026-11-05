#!/usr/bin/env python3
"""生成 3YE music Plus 的 1024x1024 App 图标（纯标准库，无 Pillow 依赖）。

设计：深海军蓝→墨青渐变底 + 右上一团青绿光晕，中央五根圆头均衡器竖条。
iOS 会自动裁成 squircle，所以这里全幅铺满、不做圆角。
"""
import math
import struct
import zlib

S = 1024
OUT = "YEMusicPlus/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v


def smoothstep(edge0, edge1, x):
    t = clamp((x - edge0) / (edge1 - edge0))
    return t * t * (3.0 - 2.0 * t)


def sd_round_box(px, py, cx, cy, hw, hh, r):
    """圆角矩形的有符号距离（<0 在内部）。"""
    qx = abs(px - cx) - hw + r
    qy = abs(py - cy) - hh + r
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r


# 五根竖条：半高（相对画布）、中心 x（相对画布）
BARS = [
    (0.140, 0.500 - 0.195),
    (0.235, 0.500 - 0.0975),
    (0.335, 0.500),
    (0.200, 0.500 + 0.0975),
    (0.135, 0.500 + 0.195),
]
BAR_HW = 0.0375
CY = 0.500

# 底：深海军蓝 → 墨青
TOP = (0.028, 0.075, 0.125)
BOT = (0.055, 0.185, 0.235)
GLOW = (0.16, 0.86, 0.72)   # 青绿光晕
BAR_COL = (0.949, 0.980, 1.0)
ACCENT = (0.42, 0.92, 0.84)

rows = []
for y in range(S):
    fy = y / (S - 1)
    row = bytearray()
    row.append(0)  # PNG filter type 0
    for x in range(S):
        fx = x / (S - 1)

        # 竖向渐变
        t = smoothstep(0.0, 1.0, fy)
        r = TOP[0] + (BOT[0] - TOP[0]) * t
        g = TOP[1] + (BOT[1] - TOP[1]) * t
        b = TOP[2] + (BOT[2] - TOP[2]) * t

        # 右上光晕
        d = math.hypot(fx - 0.74, fy - 0.20)
        glow = smoothstep(0.62, 0.0, d) * 0.55
        r += (GLOW[0] - r) * glow
        g += (GLOW[1] - g) * glow
        b += (GLOW[2] - b) * glow

        # 竖条（带包围盒早退）
        alpha = 0.0
        tint = 0.0
        for hh, cx in BARS:
            if abs(fx - cx) > BAR_HW + 0.01 or abs(fy - CY) > hh + 0.01:
                continue
            hh_px = hh * (S - 1)
            hw_px = BAR_HW * (S - 1)
            r_corner = min(hw_px, hh_px)
            dbox = sd_round_box(fx * (S - 1), fy * (S - 1),
                                cx * (S - 1), CY * (S - 1),
                                hw_px, hh_px, r_corner)
            a = 1.0 - smoothstep(-1.1, 1.1, dbox)
            if a > alpha:
                alpha = a
                tint = 1.0 if abs(cx - 0.5) < 1e-6 else 0.0

        if alpha > 0.0:
            br = BAR_COL[0] + (ACCENT[0] - BAR_COL[0]) * tint
            bg = BAR_COL[1] + (ACCENT[1] - BAR_COL[1]) * tint
            bb = BAR_COL[2] + (ACCENT[2] - BAR_COL[2]) * tint
            r += (br - r) * alpha
            g += (bg - g) * alpha
            b += (bb - b) * alpha

        row += bytes((
            int(clamp(r) * 255 + 0.5),
            int(clamp(g) * 255 + 0.5),
            int(clamp(b) * 255 + 0.5),
            255,
        ))
    rows.append(bytes(row))

raw = b"".join(rows)


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))

with open(OUT, "wb") as f:
    f.write(png)
print("wrote", OUT, len(png), "bytes")
