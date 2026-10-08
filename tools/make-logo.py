#!/usr/bin/env python3
"""从源图生成 App 图标与界面用的 logo。

为什么要脚本而不是直接塞图：图标要求正方形、界面要求按 @2x/@3x 出图，
而源图是宽幅 JPEG。手改一次可以，换 logo 时就容易漏掉某个尺寸 —— 所以固定成一条命令。

产物：
  CCUPad/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png   1024x1024 白底
  CCUPad/Resources/Assets.xcassets/Logo.imageset/logo.png                界面用（1x/2x/3x）

用法：python tools/make-logo.py [源图路径]
默认源图：artwork/sony-logo.jpg

依赖：Pillow（工作区自带的 Python 已包含）。
"""

import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def find_assets(repo):
    """找出 App 真正的 Assets.xcassets（含 AppIcon.appiconset 的那个）。

    不写死相对路径：以前按 `CCUPad/Resources/...` 拼，层数差一层就会**默默新建一棵
    平行目录**，图片生成了、构建却看不到（真踩过）。找不到就报错退出。
    """
    for root, dirs, _ in os.walk(repo):
        if os.path.basename(root) == "Assets.xcassets" and "AppIcon.appiconset" in dirs:
            return root
    return None


ASSETS = find_assets(REPO)
if ASSETS is None:
    raise SystemExit(f"在 {REPO} 下没找到含 AppIcon.appiconset 的 Assets.xcassets —— 先确认仓库结构")

SOURCE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "artwork", "sony-logo.jpg")

# 判定「墨迹」的阈值：源图是白底黑字，JPEG 压缩后边缘会有灰，取 200 足够稳
INK_THRESHOLD = 200


def ink_bbox(image):
    """非白像素的外接框（用最小值通道，避免彩色噪声干扰）。"""
    gray = image.convert("L")
    mask = gray.point(lambda v: 255 if v < INK_THRESHOLD else 0)
    box = mask.getbbox()
    if box is None:
        raise SystemExit("源图里没找到任何非白像素 —— 检查源图路径")
    return box


def main():
    if not os.path.exists(SOURCE):
        raise SystemExit(f"找不到源图：{SOURCE}")
    src = Image.open(SOURCE).convert("RGB")
    box = ink_bbox(src)
    ink = src.crop(box)
    print(f"源图 {src.size[0]}x{src.size[1]}，墨迹区域 {ink.size[0]}x{ink.size[1]}")
    print(f"输出到 {ASSETS}")

    # ---------------------------------------------------------------- App 图标
    # 正方形白底，logo 水平居中，占宽 82%（字号识别度与留白的常见折中）
    side = 1024
    canvas = Image.new("RGB", (side, side), (255, 255, 255))
    target_w = int(side * 0.82)
    scale = target_w / ink.size[0]
    target_h = max(1, int(round(ink.size[1] * scale)))
    resized = ink.resize((target_w, target_h), Image.LANCZOS)
    canvas.paste(resized, ((side - target_w) // 2, (side - target_h) // 2))

    icon_dir = os.path.join(ASSETS, "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)
    icon_path = os.path.join(icon_dir, "AppIcon-1024.png")
    canvas.save(icon_path, "PNG")
    print(f"  → {os.path.relpath(icon_path, REPO)}  {side}x{side}")

    # ---------------------------------------------------------------- 界面用 logo
    # 留一点白边，让「白底卡片」看起来是刻意的；出 1x/2x/3x 三档
    logo_dir = os.path.join(ASSETS, "Logo.imageset")
    os.makedirs(logo_dir, exist_ok=True)
    margin = 0.06
    for name, width in (("logo.png", 700), ("logo@2x.png", 1400), ("logo@3x.png", 2100)):
        pad = int(round(width * margin))
        inner_w = width - 2 * pad
        inner_h = max(1, int(round(ink.size[1] * (inner_w / ink.size[0]))))
        card = Image.new("RGB", (width, inner_h + 2 * pad), (255, 255, 255))
        card.paste(ink.resize((inner_w, inner_h), Image.LANCZOS), (pad, pad))
        out = os.path.join(logo_dir, name)
        card.save(out, "PNG")
        print(f"  → {os.path.relpath(out, REPO)}  {card.size[0]}x{card.size[1]}")


if __name__ == "__main__":
    main()
