#!/usr/bin/env python3
"""Генератор темы Ventoy «DNS» (оранжевая шапка, тёмный фон).

Создаёт папку  ventoy/  (рядом со скриптом), которую нужно скопировать
в корень флешки Ventoy:

    ventoy/ventoy.json
    ventoy/theme/theme.txt
    ventoy/theme/background.png
    ventoy/theme/menu_*.png, select_*.png

Заголовок и подзаголовок «зашиты» в background.png, поэтому их можно
поменять ключами командной строки и перегенерировать тему:

    python build_theme.py --title DNS \
        --subtitle "Windows 11 Домашняя / Pro · инструменты · восстановление"

Нужен Python 3 + Pillow (pip install pillow).
"""
import argparse
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1024, 768

# Цвета сняты с эталонного скриншота
ORANGE = (252, 133, 7)
BG = (24, 24, 26)
PANEL = (38, 41, 45)
SUBTITLE = (255, 244, 230)
SEL_FILL = (45, 87, 110)
SEL_BORDER = (53, 130, 171)

# Геометрия в пикселях для режима 1024x768 (он задан в ventoy.json → gfxmode).
# GRUB понимает в theme.txt только целые проценты, поэтому меню задаём в пикселях.
HEADER_SOLID_END = 169      # до этой строки сплошной оранжевый
HEADER_FADE_END = 207       # к этой строке градиент уходит в фон
LINE_Y = (207, 209)         # оранжевая линия-разделитель (2 px)
PANEL_X = (102, 921)        # x0 включительно, x1 исключительно
PANEL_Y = (240, 584)        # область меню
STRIP_Y = (585, 614)        # нижняя полоска панели

FONT_DIRS = [
    "/usr/share/fonts/truetype/liberation",
    "/usr/share/fonts/truetype/liberation2",
    "/usr/share/fonts/liberation-sans",
    "/usr/share/fonts/TTF",
    "/Library/Fonts",
    os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts"),
]
BOLD_FONTS = ["LiberationSans-Bold.ttf", "arialbd.ttf", "Arial Bold.ttf", "DejaVuSans-Bold.ttf"]
REGULAR_FONTS = ["LiberationSans-Regular.ttf", "arial.ttf", "Arial.ttf", "DejaVuSans.ttf"]


def find_font(names):
    for d in FONT_DIRS:
        for n in names:
            p = os.path.join(d, n)
            if os.path.isfile(p):
                return p
    sys.exit("Не найден шрифт (нужен Liberation Sans или Arial): " + ", ".join(names))


def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def fit_font(path, text, max_width, size):
    """Уменьшает кегль, пока текст не влезет по ширине."""
    while size > 8:
        f = ImageFont.truetype(path, size)
        if f.getlength(text) <= max_width:
            return f
        size -= 1
    return ImageFont.truetype(path, size)


def build_background(title, subtitle):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    # Шапка: сплошной оранжевый + плавный переход в тёмный фон
    for y in range(HEADER_FADE_END):
        if y < HEADER_SOLID_END:
            c = ORANGE
        else:
            t = (y - HEADER_SOLID_END) / (HEADER_FADE_END - HEADER_SOLID_END)
            c = mix(ORANGE, BG, smoothstep(t))
        d.line([(0, y), (W - 1, y)], fill=c)

    # Оранжевая линия под шапкой
    d.rectangle([PANEL_X[0], LINE_Y[0], PANEL_X[1] - 1, LINE_Y[1] - 1], fill=ORANGE)

    # Панель меню и нижняя полоска
    d.rectangle([PANEL_X[0], PANEL_Y[0], PANEL_X[1] - 2, PANEL_Y[1] - 1], fill=PANEL)
    d.rectangle([PANEL_X[0], STRIP_Y[0], PANEL_X[1] - 2, STRIP_Y[1] - 1], fill=PANEL)

    # Заголовок с тенью
    bold = fit_font(find_font(BOLD_FONTS), title, W - 80, 76)
    cx, cy = W // 2, 89
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).text((cx + 3, cy + 3), title, font=bold, fill=230, anchor="mm")
    shadow = shadow.filter(ImageFilter.GaussianBlur(1.2))
    img.paste((0, 0, 0), (0, 0), shadow)
    d.text((cx, cy), title, font=bold, fill=(255, 255, 255), anchor="mm")

    # Подзаголовок
    if subtitle:
        reg = fit_font(find_font(REGULAR_FONTS), subtitle, W - 80, 24)
        d.text((cx, 155), subtitle, font=reg, fill=SUBTITLE, anchor="mm")
    return img


def nine_slice(prefix, outdir, l, t, r, b, center, border=None):
    """Сохраняет prefix_{nw,n,ne,w,c,e,sw,s,se}.png.

    border=None  -> рамка прозрачная (используется только как отступ);
    иначе рамка залита цветом border.
    """
    clear = (0, 0, 0, 0)
    edge = clear if border is None else border + (255,)
    parts = {
        "nw": ((l, t), edge), "n": ((1, t), edge), "ne": ((r, t), edge),
        "w": ((l, 1), edge), "c": ((1, 1), center), "e": ((r, 1), edge),
        "sw": ((l, b), edge), "s": ((1, b), edge), "se": ((r, b), edge),
    }
    for name, (size, color) in parts.items():
        Image.new("RGBA", size, color).save(os.path.join(outdir, f"{prefix}_{name}.png"))


THEME_TXT = """\
# Тема Ventoy «DNS». Сгенерировано build_theme.py — правьте генератор, а не этот файл.
desktop-image: "background.png"
desktop-color: "#18181a"
title-text: ""
message-color: "#f2f2f2"
message-bg-color: "#18181a"

+ boot_menu {{
  left = {menu_left}
  top = {menu_top}
  width = {menu_width}
  height = {menu_height}

  # прозрачная рамка задаёт внутренние отступы, сама панель нарисована на фоне
  menu_pixmap_style = "menu_*.png"
  item_padding = 20

  item_color = "#c9ced6"
  selected_item_color = "#f2f2f2"
  selected_item_pixmap_style = "select_*.png"
  item_height = 28
  item_spacing = 4
  icon_width = 32
  icon_height = 28
  item_icon_space = 0

  scrollbar = true
  scrollbar_width = 8
  scrollbar_thumb = "slider_*.png"
}}

# обратный отсчёт («21s») справа внизу
+ progress_bar {{
  id = "__timeout__"
  text = "@TIMEOUT_NOTIFICATION_SHORT@"
  left = 90%
  top = 90%
  width = 10%
  height = 20
  text_color = "#ff0000"
  bar_style = "*"
  highlight_style = "*"
}}

# строка горячих клавиш (версия Ventoy выводится через ventoy_left/top в ventoy.json)
+ hbox {{
  left = 5%+235
  top = 95%
  width = 70%
  height = 25
  + label {{ text = "@VTOY_HOTKEY_TIP@" color = "#9ec5ff" align = "left" }}
}}

# служебные индикаторы режимов Ventoy — над полоской горячих клавиш
+ hbox {{
  left = 10%
  top = 95%-50
  width = 10%
  height = 25
  + label {{ text = "@VTOY_ISO_RAW@" color = "red" align = "left" }}
}}
+ hbox {{
  left = 10%+200
  top = 95%-50
  width = 10%
  height = 25
  + label {{ text = "@VTOY_GRUB2_MODE@" color = "red" align = "left" }}
}}
+ hbox {{
  left = 10%+400
  top = 95%-50
  width = 10%
  height = 25
  + label {{ text = "@VTOY_WIMBOOT_MODE@" color = "red" align = "left" }}
}}
+ hbox {{
  left = 10%+600
  top = 95%-50
  width = 10%
  height = 25
  + label {{ text = "@VTOY_MEM_DISK@" color = "red" align = "left" }}
}}
+ hbox {{
  left = 90%
  top = 55
  width = 10%
  height = 25
  + label {{ text = "@VTOY_ISO_UEFI_DRV@" color = "red" align = "left" }}
}}
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--title", default="DNS")
    ap.add_argument("--subtitle", default="Windows 11 Домашняя / Pro · инструменты · восстановление")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "ventoy"))
    a = ap.parse_args()

    theme_dir = os.path.join(a.out, "theme")
    os.makedirs(theme_dir, exist_ok=True)

    build_background(a.title, a.subtitle).save(os.path.join(theme_dir, "background.png"), optimize=True)

    # Рамка меню: прозрачная, задаёт отступы (left 11, top 1, right 11, bottom 1)
    nine_slice("menu", theme_dir, 11, 1, 11, 1, (0, 0, 0, 0))
    # Выделенный пункт: заливка + рамка 1 px
    nine_slice("select", theme_dir, 1, 1, 1, 1, SEL_FILL + (255,), border=SEL_BORDER)
    # Ползунок прокрутки (виден, только если пунктов больше, чем влезает)
    nine_slice("slider", theme_dir, 1, 1, 1, 1, (90, 96, 104, 255), border=(90, 96, 104))

    with open(os.path.join(theme_dir, "theme.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(THEME_TXT.format(
            menu_left=PANEL_X[0],
            menu_top=PANEL_Y[0],
            menu_width=PANEL_X[1] - PANEL_X[0],
            menu_height=PANEL_Y[1] - PANEL_Y[0],
        ))

    ventoy_json = {
        "theme": {
            "file": "/ventoy/theme/theme.txt",
            "gfxmode": "1024x768",
            "display_mode": "GUI",
            "ventoy_left": "5%",
            "ventoy_top": "95%",
            "ventoy_color": "#9ec5ff",
        }
    }
    with open(os.path.join(a.out, "ventoy.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(ventoy_json, f, ensure_ascii=False, indent=4)
        f.write("\n")

    print("Тема собрана в", a.out)


if __name__ == "__main__":
    main()
