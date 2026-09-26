#!/usr/bin/env python3
"""WCAG contrast check for the Appendix A token pairs. Run: python3 ios/scripts/contrast.py"""


def lum(h):
    h = h.lstrip('#')
    r, g, b = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    f = lambda c: c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)


def cr(a, b):
    la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


LIGHT = {'lavender': ('#E4DDFB', '#6B5BD2'), 'mint': ('#D5F0E3', '#2E8B63'), 'peach': ('#FFE2D3', '#C0623A'),
         'sky': ('#DCEBFA', '#3A73B5'), 'butter': ('#FCF0C4', '#9A7A12'), 'rose': ('#FADADF', '#C23B4E')}
DARK = {'lavender': ('#3A3358', '#C9BEFF'), 'mint': ('#23423A', '#9FE0C2'), 'peach': ('#4A3128', '#FFBFA0'),
        'sky': ('#233447', '#A9CCF2'), 'butter': ('#463E22', '#F2DB8A'), 'rose': ('#4A262D', '#FFA9B5')}

if __name__ == '__main__':
    for n, (fill, strong) in LIGHT.items():
        print(f"light {n:9} strong-on-fill {cr(fill, strong):.2f}  on-bg {cr('#FBF8F4', strong):.2f}")
    for n, (fill, strong) in DARK.items():
        print(f"dark  {n:9} strong-on-fill {cr(fill, strong):.2f}  on-surface {cr('#1E2028', strong):.2f}")
    for a, b in [('#1F2330', '#FBF8F4'), ('#5B6172', '#FBF8F4'), ('#9AA0AE', '#FBF8F4'), ('#5B6172', '#F4EFE9'),
                 ('#F2F1F6', '#15161C'), ('#A9ADBB', '#1E2028'), ('#6E7385', '#1E2028')]:
        print(f"{a} on {b}: {cr(a, b):.2f}")


def adjust(hexcolor, against, target=4.6, darken=True):
    """Scale RGB toward black (or white) until contrast >= target. Returns the adjusted hex."""
    h = hexcolor.lstrip('#')
    rgb = [int(h[i:i + 2], 16) for i in (0, 2, 4)]
    for step in range(0, 101):
        t = step / 100
        c = [round(v * (1 - t)) if darken else round(v + (255 - v) * t) for v in rgb]
        hx = '#%02X%02X%02X' % tuple(c)
        if cr(hx, against) >= target:
            return hx
    return hexcolor


def suggest():
    for n, (fill, strong) in LIGHT.items():
        # Must pass on its pastel fill and on white surfaces.
        worst = fill if lum(fill) < lum('#FFFFFF') else '#FFFFFF'
        print(n, strong, '->', adjust(strong, worst))
    print('inkTertiary light', adjust('#9AA0AE', '#FBF8F4', 4.5))
    print('inkTertiary dark', adjust('#6E7385', '#1E2028', 4.5, darken=False))
