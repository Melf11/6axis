#!/usr/bin/env python3
"""Generates the 6axis logo (Resources/Logo.svg and Resources/LogoMark.svg).

Three axes in isometric arrangement = six directions, forming a crosshair.
X red, Y green, Z blue (CAD convention). Positive directions end in a glowing node,
negative directions taper off. Re-run after changing the design, then scripts/make-icon.sh.
"""
import math, os

ROOT = os.path.join(os.path.dirname(__file__), "..", "Resources")
C = 512.0
AXES = [  # (positive angle in degrees, SVG coords: 0 = right, clockwise), color, light color
    (-90, "#4F8BFF", "#A9C6FF"),   # +Z up
    (150, "#FF5D6C", "#FFB0B8"),   # +X lower left
    (30,  "#34D399", "#A7F3D0"),   # +Y lower right
]

def pt(angle, r):
    a = math.radians(angle)
    return C + r * math.cos(a), C + r * math.sin(a)

def mark(include_background: bool) -> str:
    out = []
    defs = []
    if include_background:
        defs.append('''
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#26304F"/>
      <stop offset="1" stop-color="#0A0E1C"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.47" r="0.55">
      <stop offset="0" stop-color="#5B7CFF" stop-opacity="0.30"/>
      <stop offset="0.6" stop-color="#5B7CFF" stop-opacity="0.06"/>
      <stop offset="1" stop-color="#5B7CFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.28"/>
      <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.04"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.10"/>
    </linearGradient>''')
        # macOS icon grid: 824 x 824 rounded square centered in 1024, soft drop shadow.
        for i, (dy, op) in enumerate([(14, 0.10), (8, 0.12), (4, 0.16)]):
            out.append(f'<rect x="{100 - i * 2}" y="{100 + dy}" width="{824 + i * 4}" height="{824 + i * 2}" rx="{188 + i * 2}" fill="#000" opacity="{op}"/>')
        out.append('<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>')
        out.append('<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#glow)"/>')
        out.append('<rect x="102" y="102" width="820" height="820" rx="183" fill="none" stroke="url(#rim)" stroke-width="4"/>')
        defs.append('<clipPath id="squircle"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>')
        out.append('<g clip-path="url(#squircle)">')

    ring_color = "#FFFFFF" if include_background else "#8A93A8"
    # Reticle ring broken where the axes pass, plus ticks between the axes.
    R = 286
    gap = 22  # degrees
    for k in range(6):
        a0 = 30 + 60 * k + gap / 2
        a1 = 30 + 60 * (k + 1) - gap / 2
        x0, y0 = pt(a0, R); x1, y1 = pt(a1, R)
        out.append(f'<path d="M{x0:.1f},{y0:.1f} A{R},{R} 0 0 1 {x1:.1f},{y1:.1f}" fill="none" stroke="{ring_color}" stroke-opacity="0.22" stroke-width="9" stroke-linecap="round"/>')
        tx0, ty0 = pt(60 * k, R - 34); tx1, ty1 = pt(60 * k, R + 10)
        out.append(f'<line x1="{tx0:.1f}" y1="{ty0:.1f}" x2="{tx1:.1f}" y2="{ty1:.1f}" stroke="{ring_color}" stroke-opacity="0.45" stroke-width="10" stroke-linecap="round"/>')
    # Fine inner ring.
    out.append(f'<circle cx="{C}" cy="{C}" r="168" fill="none" stroke="{ring_color}" stroke-opacity="0.10" stroke-width="5"/>')

    for i, (ang, col, light) in enumerate(AXES):
        # Negative direction: thinner, fading towards the tip.
        nx0, ny0 = pt(ang + 180, 76); nx1, ny1 = pt(ang + 180, 300)
        defs.append(f'''
    <linearGradient id="neg{i}" gradientUnits="userSpaceOnUse" x1="{nx0:.1f}" y1="{ny0:.1f}" x2="{nx1:.1f}" y2="{ny1:.1f}">
      <stop offset="0" stop-color="{col}" stop-opacity="0.85"/>
      <stop offset="1" stop-color="{col}" stop-opacity="0.08"/>
    </linearGradient>''')
        out.append(f'<line x1="{nx0:.1f}" y1="{ny0:.1f}" x2="{nx1:.1f}" y2="{ny1:.1f}" stroke="url(#neg{i})" stroke-width="22" stroke-linecap="round"/>')
        # Positive direction: bold, brightening towards a glowing node.
        px0, py0 = pt(ang, 76); px1, py1 = pt(ang, 300)
        defs.append(f'''
    <linearGradient id="pos{i}" gradientUnits="userSpaceOnUse" x1="{px0:.1f}" y1="{py0:.1f}" x2="{px1:.1f}" y2="{py1:.1f}">
      <stop offset="0" stop-color="{col}" stop-opacity="0.75"/>
      <stop offset="1" stop-color="{light}"/>
    </linearGradient>
    <radialGradient id="node{i}">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="0.35" stop-color="{light}"/>
      <stop offset="1" stop-color="{col}"/>
    </radialGradient>
    <radialGradient id="halo{i}">
      <stop offset="0" stop-color="{col}" stop-opacity="0.55"/>
      <stop offset="1" stop-color="{col}" stop-opacity="0"/>
    </radialGradient>''')
        out.append(f'<line x1="{px0:.1f}" y1="{py0:.1f}" x2="{px1:.1f}" y2="{py1:.1f}" stroke="url(#pos{i})" stroke-width="38" stroke-linecap="round"/>')
        hx, hy = pt(ang, 330)
        out.append(f'<circle cx="{hx:.1f}" cy="{hy:.1f}" r="66" fill="url(#halo{i})"/>')
        out.append(f'<circle cx="{hx:.1f}" cy="{hy:.1f}" r="32" fill="url(#node{i})"/>')

    # Center: crosshair eye.
    center_col = "#FFFFFF" if include_background else "#1C2238"
    out.append(f'<circle cx="{C}" cy="{C}" r="50" fill="none" stroke="{center_col}" stroke-width="14"/>')
    out.append(f'<circle cx="{C}" cy="{C}" r="15" fill="{center_col}"/>')

    if include_background:
        out.append('</g>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            '  <defs>' + "".join(defs) + '\n  </defs>\n  ' + "\n  ".join(out) + '\n</svg>\n')

os.makedirs(ROOT, exist_ok=True)
open(os.path.join(ROOT, "Logo.svg"), "w").write(mark(True))
open(os.path.join(ROOT, "LogoMark.svg"), "w").write(mark(False))
print("wrote Resources/Logo.svg and Resources/LogoMark.svg")
