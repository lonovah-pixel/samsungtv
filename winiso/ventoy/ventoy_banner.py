#!/usr/bin/env python3
"""
Замена баннера (фонового изображения темы) в меню Ventoy без переустановки Ventoy.

Ventoy берёт тему из плагина "theme" в /ventoy/ventoy.json на разделе данных флешки.
Без плагина используется встроенная тема (раздел VTOYEFI, grub/themes/ventoy), где логотип
Ventoy нарисован прямо в background.png (1024x768). Поэтому «баннер» — это desktop-image темы.

Команды:
  inspect  ROOT                 — показать носитель, ventoy.json, активную тему и ресурс баннера
  make-banner --out PNG ...     — подготовить картинку (из исходника или черновой вариант)
  plan     ROOT --banner PNG    — список планируемых изменений (ничего не пишет)
  apply    ROOT --banner PNG --confirm TOKEN — применить (TOKEN печатает plan)
  rollback ROOT [--backup ID]   — откат по резервной копии
  stage    --out DIR --banner PNG — готовая папка для ручного копирования, если флешка недоступна

Не форматирует, не меняет разделы и не переустанавливает Ventoy: только файлы в /ventoy/.
Зависимости: Python 3.8+; Pillow нужен только для make-banner.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE_THEME = HERE / "base-theme"          # встроенная тема Ventoy 1.1.18 (GPLv3), без изменений
THEME_DIR_REL = "ventoy/themes/winiso"     # куда кладётся новая тема, если своей нет
BACKUP_DIR_REL = "ventoy/winiso_backup"
DEFAULT_SIZE = (1024, 768)                 # gfxmode Ventoy по умолчанию
MENU_TOP_FRACTION = 0.30                   # boot_menu.top в стандартной теме


class Fail(Exception):
    pass


# --------------------------------------------------------------------------- утилиты
def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def png_info(path: Path) -> dict:
    """Читает IHDR без сторонних библиотек и проверяет совместимость с загрузчиком GRUB."""
    with open(path, "rb") as f:
        head = f.read(29)
    if len(head) < 29 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise Fail(f"{path}: не PNG")
    w, h, depth, ctype, _c, _f, interlace = struct.unpack(">IIBBBBB", head[16:29])
    problems = []
    if depth != 8:
        problems.append(f"глубина {depth} бит (нужно 8)")
    if ctype not in (2, 6):
        problems.append("цветовой тип должен быть RGB или RGBA (не палитра/оттенки серого)")
    if interlace:
        problems.append("чересстрочный PNG не поддерживается GRUB")
    return {"width": w, "height": h, "depth": depth, "color_type": ctype, "interlace": interlace, "problems": problems}


def bottom_is_dark(banner: Path):
    """True/False — тёмная ли нижняя полоса баннера (там строка версии и горячих клавиш); None без Pillow."""
    try:
        from PIL import Image
    except ImportError:
        return None
    with Image.open(banner) as im:
        g = im.convert("L")
        w, h = g.size
        strip = g.crop((0, int(h * 0.90), w, h)).resize((64, 8))
        data = strip.tobytes()
    return sum(data) / len(data) < 110


def read_json_strict(path: Path):
    raw = path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw[3:].decode("utf-8") if bom else raw.decode("utf-8")
    try:
        data = json.loads(text, object_pairs_hook=OrderedDict)
    except json.JSONDecodeError as e:
        raise Fail(f"{path}: синтаксическая ошибка JSON ({e}). Ventoy в этом случае игнорирует все плагины; "
                   "исправьте файл (например, VentoyPlugson) — автоматически не трогаю.")
    if not isinstance(data, dict):
        raise Fail(f"{path}: корень JSON должен быть объектом")
    return data, bom


def resolve_theme_path(root: Path, value: str) -> Path:
    # Так же, как ventoy_plugin.c: "/x" — от корня раздела, иначе относительно /ventoy/.
    return root / value.lstrip("/") if value.startswith("/") else root / "ventoy" / value


def parse_theme_txt(path: Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r'^\s*desktop-image\s*:\s*"([^"]+)"', text, re.M)
    images = re.findall(r'\+\s*image\s*\{[^}]*?file\s*=\s*"([^"]+)"', text, re.S)
    return {"desktop_image": m.group(1) if m else None, "image_components": images}


# --------------------------------------------------------------------------- носитель
def run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return ""


def device_info(root: Path) -> dict:
    info = {"root": str(root), "os": platform.system()}
    if platform.system() == "Linux":
        line = run(["findmnt", "-n", "-o", "SOURCE,FSTYPE,TARGET", "--target", str(root)]).split()
        if line:
            info.update(source=line[0], fstype=line[1], mountpoint=line[2])
            blk = run(["lsblk", "-J", "-b", "-o", "NAME,PATH,PKNAME,SIZE,LABEL,UUID,FSTYPE,MODEL,SERIAL,TRAN,RM", line[0]])
            if blk:
                dev = json.loads(blk)["blockdevices"][0]
                info.update(label=dev.get("label"), uuid=dev.get("uuid"), part_size=dev.get("size"))
                parent = dev.get("pkname")
                if parent:
                    disk = json.loads(run(["lsblk", "-J", "-b", "-o", "NAME,PATH,SIZE,LABEL,MODEL,SERIAL,TRAN,RM", "/dev/" + parent]))["blockdevices"][0]
                    info.update(disk=disk.get("path"), disk_size=disk.get("size"), model=disk.get("model"),
                                serial=disk.get("serial"), transport=disk.get("tran"), removable=disk.get("rm"))
                    labels = [c.get("label") for c in disk.get("children", [])]
                    info["ventoy_efi_partition"] = "VTOYEFI" in labels
            if not info.get("label") or not info.get("uuid"):
                probe = run(["blkid", "-o", "export", line[0]])
                kv = dict(l.split("=", 1) for l in probe.splitlines() if "=" in l)
                info.setdefault("label", kv.get("LABEL")); info["label"] = info["label"] or kv.get("LABEL")
                info["uuid"] = info.get("uuid") or kv.get("UUID")
    elif platform.system() == "Windows":
        drive = str(root.resolve())[:1]
        ps = (f"$v=Get-Volume -DriveLetter {drive}; $p=Get-Partition -DriveLetter {drive}; $d=Get-Disk -Number $p.DiskNumber;"
              "$l=@(Get-Partition -DiskNumber $p.DiskNumber | Get-Volume -ErrorAction SilentlyContinue | % FileSystemLabel);"
              "[pscustomobject]@{label=$v.FileSystemLabel;fstype=$v.FileSystem;part_size=$v.Size;uuid=$v.UniqueId;"
              "disk=('Disk '+$d.Number);disk_size=$d.Size;model=$d.FriendlyName;serial=$d.SerialNumber;transport=[string]$d.BusType;"
              "ventoy_efi_partition=($l -contains 'VTOYEFI')} | ConvertTo-Json")
        out = run(["powershell", "-NoProfile", "-Command", ps])
        if out:
            info.update(json.loads(out))
            info["mountpoint"] = f"{drive}:\\"
            m = re.search(r"\{([0-9a-fA-F-]+)\}", str(info.get("uuid", "")))
            info["uuid"] = m.group(1) if m else info.get("uuid")
    info["is_ventoy_data"] = (root / "ventoy").is_dir() or info.get("ventoy_efi_partition") is True
    return info


def confirm_token(info: dict) -> str:
    return f"{info.get('label') or 'NOLABEL'}-{info.get('uuid') or info.get('serial') or 'NOID'}"


def print_device(info: dict) -> None:
    def gb(v):
        try:
            return f"{int(v) / 1e9:.1f} ГБ"
        except (TypeError, ValueError):
            return "?"
    print("Носитель:")
    print(f"  точка подключения : {info.get('mountpoint', info['root'])}")
    print(f"  раздел/устройство : {info.get('source', '')} {info.get('fstype', '')}, {gb(info.get('part_size'))}")
    print(f"  метка / UUID      : {info.get('label')} / {info.get('uuid')}")
    print(f"  диск              : {info.get('disk', '?')} {gb(info.get('disk_size'))} {info.get('model') or ''} "
          f"serial={info.get('serial') or '?'} шина={info.get('transport') or '?'}")
    vefi = info.get("ventoy_efi_partition")
    print(f"  раздел VTOYEFI    : {'найден' if vefi else ('не найден' if vefi is False else 'не удалось определить')}")


# --------------------------------------------------------------------------- анализ
def inspect(root: Path) -> dict:
    if not root.is_dir():
        raise Fail(f"{root}: папка не найдена (флешка не подключена?)")
    vj = root / "ventoy" / "ventoy.json"
    res = {"root": root, "ventoy_json": vj, "json": None, "bom": False, "themes": [], "mode": None}
    if vj.exists():
        res["json"], res["bom"] = read_json_strict(vj)
        for key, val in res["json"].items():
            if not key.startswith("theme"):
                continue
            files = val.get("file") if isinstance(val, dict) else None
            for f in ([files] if isinstance(files, str) else files or []):
                p = resolve_theme_path(root, f)
                entry = {"key": key, "file": f, "path": p, "exists": p.is_file()}
                if p.is_file():
                    entry.update(parse_theme_txt(p))
                    if entry["desktop_image"]:
                        img = p.parent / entry["desktop_image"]
                        entry["desktop_image_path"] = img
                        entry["desktop_image_exists"] = img.is_file()
                        if img.is_file() and img.suffix.lower() == ".png":
                            entry["desktop_image_info"] = png_info(img)
                res["themes"].append(entry)
    usable = [t for t in res["themes"] if t["exists"] and t.get("desktop_image_exists")]
    if usable:
        res["mode"] = "replace-existing"
    elif res["themes"]:
        res["mode"] = "broken-theme"
    else:
        res["mode"] = "new-theme"
    return res


def report_inspect(res: dict) -> None:
    root = res["root"]
    print(f"ventoy.json: {'есть' if res['json'] is not None else 'нет'} ({res['ventoy_json']})")
    if res["json"] is not None:
        print(f"  ключи плагинов: {', '.join(res['json'].keys()) or '(пусто)'}")
    if not res["themes"]:
        print("Тема: встроенная тема Ventoy (раздел VTOYEFI, grub/themes/ventoy/theme.txt).")
        print("  Баннер «Ventoy» нарисован в её background.png (1024x768) — заменить его можно только своей темой")
        print(f"  через плагин theme: будет создана копия встроенной темы в /{THEME_DIR_REL}/ с новым background.png.")
    for t in res["themes"]:
        print(f"Тема [{t['key']}]: {t['file']} -> {t['path']} ({'есть' if t['exists'] else 'НЕТ ФАЙЛА — Ventoy использует встроенную'})")
        if t["exists"]:
            print(f"  desktop-image: {t.get('desktop_image')} ({'есть' if t.get('desktop_image_exists') else 'нет'})")
            if t.get("desktop_image_info"):
                i = t["desktop_image_info"]
                print(f"    {i['width']}x{i['height']}, {i['depth']} бит, тип {i['color_type']}")
            if t.get("image_components"):
                print(f"  компоненты image (логотипы): {', '.join(t['image_components'])}")
    print(f"Режим замены: {res['mode']}")
    _ = root


# --------------------------------------------------------------------------- план
def build_plan(res: dict, banner: Path, text_color: str = "auto") -> dict:
    root = res["root"]
    binfo = png_info(banner)
    if binfo["problems"]:
        raise Fail(f"{banner}: {'; '.join(binfo['problems'])}. Подготовьте файл командой make-banner.")
    plan = {"writes": [], "json_change": None, "notes": []}
    if res["mode"] == "replace-existing":
        seen = set()
        for t in res["themes"]:
            if not t.get("desktop_image_exists") or t["desktop_image_path"] in seen:
                continue
            seen.add(t["desktop_image_path"])
            cur = t.get("desktop_image_info")
            if cur and (cur["width"], cur["height"]) != (binfo["width"], binfo["height"]):
                plan["notes"].append(f"Размер нового баннера {binfo['width']}x{binfo['height']} отличается от текущего "
                                     f"{cur['width']}x{cur['height']} ({t['desktop_image_path'].name}); GRUB растянет картинку.")
            plan["writes"].append({"dst": t["desktop_image_path"], "src": banner, "kind": "replace"})
        plan["notes"].append("theme.txt, шрифты, пункты меню и прочие ключи ventoy.json не изменяются.")
        if bottom_is_dark(banner) and not any(isinstance(res["json"].get(t["key"]), dict) and res["json"][t["key"]].get("ventoy_color") for t in res["themes"]):
            plan["notes"].append("Низ баннера тёмный, а ventoy_color не задан: строка версии может быть плохо видна. "
                                 "При необходимости добавьте \"ventoy_color\": \"#9ec5ff\" в ваш ключ theme вручную.")
    elif res["mode"] == "new-theme":
        tdir = root / THEME_DIR_REL
        if tdir.exists():
            raise Fail(f"{tdir} уже существует, но не подключена в ventoy.json. Проверьте её вручную или выполните rollback.")
        color = resolve_text_color(banner, text_color)
        for f in sorted(BASE_THEME.iterdir()):
            if f.name in ("background.png", "SHA256SUMS"):
                continue
            w = {"dst": tdir / f.name, "src": f, "kind": "create"}
            if f.name == "theme.txt" and color:
                w["data"] = recolor_theme(f.read_text(encoding="utf-8"), color).encode("utf-8")
            plan["writes"].append(w)
        plan["writes"].append({"dst": tdir / "background.png", "src": banner, "kind": "create"})
        new_json = OrderedDict(res["json"] or OrderedDict())
        new_json["theme"] = OrderedDict([("file", "/" + THEME_DIR_REL + "/theme.txt")])
        if color:
            new_json["theme"]["ventoy_color"] = color
            plan["notes"].append(f"Фон внизу тёмный: строка версии (ventoy_color) и подсказки клавиш в копии theme.txt "
                                 f"окрашены в {color} для читаемости (иначе синий текст на тёмном фоне).")
        plan["json_change"] = {"path": res["ventoy_json"], "existed": res["json"] is not None, "new": new_json, "bom": res["bom"]}
        if (binfo["width"], binfo["height"]) != DEFAULT_SIZE:
            plan["notes"].append(f"Баннер {binfo['width']}x{binfo['height']}: стандартный gfxmode Ventoy 1024x768 — картинка будет масштабирована.")
        plan["notes"].append("Будет добавлен только ключ \"theme\"; остальные ключи ventoy.json сохраняются без изменений.")
        plan["notes"].append("Остальные ресурсы темы — копия встроенной темы Ventoy 1.1.18 (GPLv3). Если на флешке "
                             "другая версия Ventoy, вид меню может немного отличаться; на загрузку ISO это не влияет.")
    else:
        raise Fail("Тема в ventoy.json указана, но её theme.txt или desktop-image отсутствует. Исправьте путь вручную "
                   "(Ventoy сейчас использует встроенную тему) и запустите inspect снова.")
    return plan


def print_plan(plan: dict, root: Path) -> None:
    print("Планируемые изменения:")
    for w in plan["writes"]:
        state = "заменить (с резервной копией)" if w["dst"].exists() else "создать"
        print(f"  {state}: /{w['dst'].relative_to(root).as_posix()}")
    if plan["json_change"]:
        j = plan["json_change"]
        print(f"  {'изменить (с резервной копией)' if j['existed'] else 'создать'}: /ventoy/ventoy.json — ключ \"theme\"")
        print("    " + json.dumps({"theme": j["new"]["theme"]}, ensure_ascii=False))
    print(f"  создать: /{BACKUP_DIR_REL}/<время>/ — резервные копии и manifest.json для отката")
    for n in plan["notes"]:
        print(f"  * {n}")


def resolve_text_color(banner: Path, text_color: str):
    if text_color == "default":
        return None
    if text_color == "auto":
        return "#9ec5ff" if bottom_is_dark(banner) else None
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", text_color):
        raise Fail("--text-color: auto, default или #RRGGBB")
    return text_color


def recolor_theme(text: str, color: str) -> str:
    # Только метка подсказок горячих клавиш (синяя в стандартной теме); остальное без изменений.
    return re.sub(r'(\+ label \{text = "@VTOY_HOTKEY_TIP@" color = )"[^"]*"', rf'\1"{color}"', text)


# --------------------------------------------------------------------------- применение
def atomic_write_bytes(dst: Path, data: bytes) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".winiso-tmp")
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, dst)


def apply(root: Path, plan: dict, local_backup: Path | None) -> Path:
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    bdir = root / BACKUP_DIR_REL / stamp
    bdir.mkdir(parents=True, exist_ok=False)
    manifest = {"created": [], "created_dirs": [], "modified": [], "time": stamp, "tool": "winiso ventoy_banner.py"}
    done = []
    try:
        targets = [(w["dst"], w["data"] if "data" in w else w["src"].read_bytes()) for w in plan["writes"]]
        if plan["json_change"]:
            j = plan["json_change"]
            text = json.dumps(j["new"], ensure_ascii=False, indent=4) + "\n"
            data = (b"\xef\xbb\xbf" if j["bom"] else b"") + text.encode("utf-8")
            # Контроль: всё, кроме ключа theme, совпадает с исходным файлом.
            check = json.loads(text, object_pairs_hook=OrderedDict)
            old = OrderedDict(read_json_strict(j["path"])[0]) if j["existed"] else OrderedDict()
            if {k: v for k, v in check.items() if k != "theme"} != {k: v for k, v in old.items() if k != "theme"}:
                raise Fail("Контроль ventoy.json не пройден: изменились бы другие ключи.")
            targets.append((j["path"], data))
        for dst, data in targets:
            rel = dst.relative_to(root).as_posix()
            if dst.exists():
                bfile = bdir / "files" / rel
                bfile.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(dst, bfile)
                manifest["modified"].append({"path": rel, "backup_sha256": sha256(bfile), "new_sha256": hashlib.sha256(data).hexdigest()})
            else:
                manifest["created"].append({"path": rel, "sha256": hashlib.sha256(data).hexdigest()})
        new_dirs = set()
        for dst, _ in targets:
            d = dst.parent
            while d != root and not d.exists():
                new_dirs.add(d)
                d = d.parent
        manifest["created_dirs"] = sorted((d.relative_to(root).as_posix() for d in new_dirs), key=len, reverse=True)
        (bdir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
        for dst, data in targets:
            atomic_write_bytes(dst, data)
            done.append(dst)
            if hashlib.sha256(dst.read_bytes()).hexdigest() != hashlib.sha256(data).hexdigest():
                raise Fail(f"Проверка записи {dst} не пройдена")
    except Exception:
        if done:
            print("Ошибка во время записи — выполняю откат…", file=sys.stderr)
            rollback(root, bdir.name, force=True)
        raise
    if local_backup:
        dst = local_backup / stamp
        shutil.copytree(bdir, dst)
        print(f"Локальная копия резервной копии: {dst}")
    return bdir


def list_backups(root: Path) -> list[str]:
    b = root / BACKUP_DIR_REL
    return sorted(p.name for p in b.iterdir() if (p / "manifest.json").is_file()) if b.is_dir() else []


def rollback(root: Path, backup_id: str | None, force: bool = False) -> None:
    ids = list_backups(root)
    if not ids:
        raise Fail("Резервных копий на носителе нет.")
    backup_id = backup_id or ids[-1]
    bdir = root / BACKUP_DIR_REL / backup_id
    man = json.loads((bdir / "manifest.json").read_text(encoding="utf-8"))
    for m in man["modified"]:
        dst = root / m["path"]
        if not force and dst.exists() and sha256(dst) != m["new_sha256"]:
            print(f"  ! {m['path']} изменён после применения — восстанавливаю всё равно (текущая версия сохранена как .before-rollback)")
            shutil.copy2(dst, dst.with_name(dst.name + ".before-rollback"))
        atomic_write_bytes(dst, (bdir / "files" / m["path"]).read_bytes())
        print(f"  восстановлен: /{m['path']}")
    for c in man["created"]:
        dst = root / c["path"]
        if dst.exists():
            if not force and sha256(dst) != c["sha256"]:
                print(f"  ! {c['path']} изменён после применения — не удаляю")
                continue
            dst.unlink()
            print(f"  удалён: /{c['path']}")
    for d in man.get("created_dirs", []):
        try:
            (root / d).rmdir()          # только пустые папки, созданные при apply
            print(f"  удалена папка: /{d}")
        except OSError:
            pass
    shutil.move(str(bdir), str(bdir.with_name(bdir.name + ".rolled-back")))
    print(f"Откат {backup_id} выполнен.")


# --------------------------------------------------------------------------- баннер
PALETTES = {
    # верх, низ, свечение, заголовок, подзаголовок, линия; band — доли высоты начала и конца перехода верх→низ
    "blue": dict(top=(16, 32, 58), bottom=(6, 10, 20), glow=(40, 110, 200), title=(235, 242, 255), sub=(150, 185, 230), line=(70, 120, 190), band=(0.0, 1.0)),
    "orange": dict(top=(252, 133, 7), bottom=(24, 24, 26), glow=None, title=(255, 255, 255), sub=(255, 244, 230), line=(252, 133, 7), band=(0.22, 0.27)),
}


def make_banner(out: Path, source: Path | None, size: tuple[int, int], title: str, subtitle: str, palette: str = "blue") -> None:
    pal = PALETTES[palette]
    try:
        from PIL import Image, ImageDraw, ImageFont, ImageFilter
    except ImportError:
        raise Fail("Для make-banner нужен Pillow: python -m pip install pillow")
    W, H = size
    if source:
        img = Image.open(source).convert("RGB")
        scale = max(W / img.width, H / img.height)
        img = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)
        left, top = (img.width - W) // 2, (img.height - H) // 2
        img = img.crop((left, top, left + W, top + H))
        # Лёгкое затемнение зоны меню, чтобы белый текст пунктов оставался читаемым.
        shade = Image.new("L", (W, H), 0)
        ImageDraw.Draw(shade).rectangle([0, int(H * 0.28), W, int(H * 0.84)], fill=90)
        img = Image.composite(Image.new("RGB", (W, H), (0, 0, 0)), img, shade.filter(ImageFilter.GaussianBlur(24)))
    else:
        # Черновой вариант: тёмный вертикальный градиент, заголовок в верхней зоне (меню начинается на 30% высоты).
        img = Image.new("RGB", (W, H))
        top_c, bot_c = pal["top"], pal["bottom"]
        px = ImageDraw.Draw(img)
        for y in range(H):
            a0, a1 = pal["band"]
            t = min(1.0, max(0.0, (y / (H - 1) - a0) / (a1 - a0)))
            t = t * t * (3 - 2 * t)  # плавный переход
            px.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top_c, bot_c)))
        if pal["glow"]:
            glow = Image.new("L", (W, H), 0)
            ImageDraw.Draw(glow).ellipse([W * 0.2, -H * 0.25, W * 0.8, H * 0.35], fill=70)
            img = Image.composite(Image.new("RGB", (W, H), pal["glow"]), img, glow.filter(ImageFilter.GaussianBlur(60)))
    d = ImageDraw.Draw(img)
    if title:
        font_path = _find_font(bold=True)
        fsize = int(H * 0.10)
        font = ImageFont.truetype(font_path, fsize) if font_path else ImageFont.load_default()
        while font_path and d.textlength(title, font=font) > W * 0.86 and fsize > 12:
            fsize -= 2
            font = ImageFont.truetype(font_path, fsize)
        y = int(H * 0.06)
        d.text(((W - d.textlength(title, font=font)) / 2 + 2, y + 2), title, font=font, fill=(0, 0, 0))
        d.text(((W - d.textlength(title, font=font)) / 2, y), title, font=font, fill=pal["title"])
        if subtitle:
            sp = _find_font(bold=False)
            sf = ImageFont.truetype(sp, int(H * 0.032)) if sp else ImageFont.load_default()
            d.text(((W - d.textlength(subtitle, font=sf)) / 2, y + fsize * 1.25), subtitle, font=sf, fill=pal["sub"])
        d.line([(W * 0.1, H * 0.27), (W * 0.9, H * 0.27)], fill=pal["line"], width=2)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, "PNG", optimize=True)   # 8 бит RGB, без чересстрочности
    i = png_info(out)
    print(f"Баннер: {out} {i['width']}x{i['height']} RGB, SHA-256 {sha256(out)}")


def _find_font(bold: bool) -> str | None:
    names = (["DejaVuSans-Bold.ttf", "arialbd.ttf", "segoeuib.ttf", "LiberationSans-Bold.ttf"] if bold
             else ["DejaVuSans.ttf", "arial.ttf", "segoeui.ttf", "LiberationSans-Regular.ttf"])
    dirs = ["/usr/share/fonts", "/Library/Fonts", os.path.join(os.environ.get("WINDIR", "C:\\Windows"), "Fonts")]
    for d in dirs:
        for dp, _dn, fn in os.walk(d):
            for n in names:
                if n in fn:
                    return os.path.join(dp, n)
    return None


# --------------------------------------------------------------------------- stage
def stage(out: Path, banner: Path, text_color: str = "auto") -> None:
    binfo = png_info(banner)
    if binfo["problems"]:
        raise Fail(f"{banner}: {'; '.join(binfo['problems'])}")
    if out.exists() and any(out.iterdir()):
        raise Fail(f"{out} не пуста")
    tdir = out / "usb-root" / THEME_DIR_REL
    tdir.mkdir(parents=True)
    color = resolve_text_color(banner, text_color)
    for f in BASE_THEME.iterdir():
        if f.name not in ("background.png", "SHA256SUMS"):
            shutil.copy2(f, tdir / f.name)
    if color:
        (tdir / "theme.txt").write_text(recolor_theme((BASE_THEME / "theme.txt").read_text(encoding="utf-8"), color), encoding="utf-8")
    shutil.copy2(banner, tdir / "background.png")
    snippet = {"theme": {"file": "/" + THEME_DIR_REL + "/theme.txt"}}
    if color:
        snippet["theme"]["ventoy_color"] = color
    (out / "ventoy.json.theme-snippet.json").write_text(json.dumps(snippet, ensure_ascii=False, indent=4) + "\n", encoding="utf-8")
    sums = [f"{sha256(p)}  {p.relative_to(out / 'usb-root').as_posix()}" for p in sorted((out / "usb-root").rglob("*")) if p.is_file()]
    (out / "SHA256SUMS").write_text("\n".join(sums) + "\n", encoding="utf-8")
    (out / "INSTRUCTIONS.md").write_text(STAGE_README.format(theme=THEME_DIR_REL), encoding="utf-8")
    print(f"Готовая папка: {out}")


STAGE_README = """# Ручная установка баннера Ventoy

Эти действия НЕ форматируют флешку и не меняют разделы. Нужен только доступ к разделу данных
Ventoy (тот, куда копируются ISO; обычно метка `Ventoy`).

1. Сделайте резервную копию: скопируйте папку `ventoy` с флешки (если есть) в надёжное место.
2. Если на флешке уже есть `/ventoy/ventoy.json` с ключом `"theme"` — НЕ используйте эту папку:
   замените картинку, указанную в `desktop-image` вашего theme.txt (или запустите `ventoy_banner.py plan`).
3. Скопируйте содержимое `usb-root/` в корень флешки (появится `/{theme}/`).
4. Добавьте в `/ventoy/ventoy.json` ключ из `ventoy.json.theme-snippet.json`:
   - файла нет — скопируйте snippet как `/ventoy/ventoy.json`;
   - файл есть — добавьте `"theme": {{...}}` на верхний уровень объекта, не трогая остальные ключи,
     и проверьте синтаксис (VentoyPlugson или любой JSON-валидатор). При ошибке синтаксиса Ventoy
     игнорирует ВСЕ плагины.
5. Сверьте контрольные суммы: `SHA256SUMS`.
6. Загрузитесь с флешки; в меню Ventoy F5 → «Check plugin json configuration» → theme проверяет плагин.

Откат: удалите `/{theme}/` и ключ `"theme"` из ventoy.json (или верните сохранённую копию).
"""


# --------------------------------------------------------------------------- CLI
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("inspect"); p.add_argument("root", type=Path)
    p = sub.add_parser("plan"); p.add_argument("root", type=Path); p.add_argument("--banner", type=Path, required=True)
    p.add_argument("--text-color", default="auto")
    p = sub.add_parser("apply"); p.add_argument("root", type=Path); p.add_argument("--banner", type=Path, required=True)
    p.add_argument("--text-color", default="auto")
    p.add_argument("--confirm", required=True, help="токен носителя из вывода plan")
    p.add_argument("--local-backup", type=Path, default=HERE.parent / "ventoy-backups")
    p = sub.add_parser("rollback"); p.add_argument("root", type=Path); p.add_argument("--backup")
    p.add_argument("--list", action="store_true")
    p = sub.add_parser("make-banner"); p.add_argument("--out", type=Path, required=True); p.add_argument("--source", type=Path)
    p.add_argument("--size", default="1024x768"); p.add_argument("--title", default="Boot Menu"); p.add_argument("--subtitle", default="")
    p.add_argument("--palette", choices=sorted(PALETTES), default="blue")
    p = sub.add_parser("stage"); p.add_argument("--out", type=Path, required=True); p.add_argument("--banner", type=Path, required=True)
    p.add_argument("--text-color", default="auto")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "make-banner":
            w, h = (int(x) for x in a.size.lower().split("x"))
            make_banner(a.out, a.source, (w, h), a.title, a.subtitle, a.palette)
        elif a.cmd == "stage":
            stage(a.out, a.banner, a.text_color)
        elif a.cmd == "inspect":
            info = device_info(a.root); print_device(info); report_inspect(inspect(a.root))
        elif a.cmd == "plan":
            info = device_info(a.root); print_device(info)
            res = inspect(a.root); report_inspect(res); plan = build_plan(res, a.banner, a.text_color); print_plan(plan, a.root)
            print(f"\nДля применения именно к ЭТОМУ носителю: --confirm {confirm_token(info)}")
        elif a.cmd == "apply":
            info = device_info(a.root); print_device(info)
            if not info["is_ventoy_data"]:
                raise Fail("Не похоже на раздел данных Ventoy (нет /ventoy и не найден VTOYEFI). Запись отменена.")
            if a.confirm != confirm_token(info):
                raise Fail(f"Токен подтверждения не совпадает с носителем ({confirm_token(info)}). Запись отменена.")
            res = inspect(a.root); plan = build_plan(res, a.banner, a.text_color); print_plan(plan, a.root)
            bdir = apply(a.root, plan, a.local_backup)
            print(f"Готово. Резервная копия: {bdir}\nОткат: python {Path(__file__).name} rollback {a.root} --backup {bdir.name}")
        elif a.cmd == "rollback":
            if a.list:
                print("\n".join(list_backups(a.root)) or "(нет)")
            else:
                rollback(a.root, a.backup)
    except Fail as e:
        print(f"ОШИБКА: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
