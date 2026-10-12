#!/usr/bin/env python3
"""生成 App 图标（1024×1024 PNG），写进 Assets.xcassets。

为什么是脚本而不是一张图：图标要能改、能复现、能 diff。iOS 17 起只需要一张
1024 的通用图标（系统自己缩放并套圆角遮罩），所以这里只产出一个文件。

设计上只做三件事：
  · 一个深蓝→靛紫的对角渐变（跟随系统的深色观感，浅色模式下也不刺眼）；
  · 一个白色终端提示符 `❯_`（"harness / 终端"这一层意思，也是这个 App 在做的事）；
  · 图标边缘留足安全边距 —— iOS 会裁圆角，贴边的元素会被切掉。

不做文字、不做细线、不做多层装饰：图标在 60px 下要一眼认得出，
细节在缩略尺寸下只会变成噪点。

用法：
    python3 ios/scripts/make-icon.py            # 写入 Assets.xcassets
    python3 ios/scripts/make-icon.py --preview  # 额外输出一张 120px 的预览，用来验收小尺寸
"""
from __future__ import annotations

import pathlib
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    print("需要 Pillow：load_workspace_dependencies 提供的 Python 自带", file=sys.stderr)
    raise SystemExit(1)

ROOT = pathlib.Path(__file__).resolve().parents[1]
ICONSET = ROOT / "DSHPocket" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

SIZE = 1024
SUPERSAMPLE = 4          # 先画 4 倍再缩，边缘才干净（PIL 没有原生抗锯齿）

# 渐变两端。取"深海蓝 → 靛紫"，与 App 内 accent color 同一色系。
TOP = (28, 62, 138)
BOTTOM = (86, 58, 168)


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))  # type: ignore[return-value]


def make_background(size: int) -> Image.Image:
    """对角渐变。逐行画再旋转 45° 太慢，这里直接按 (x+y) 的投影做。"""
    image = Image.new("RGB", (size, size))
    pixels = image.load()
    span = 2 * size
    for y in range(size):
        for x in range(size):
            t = (x + y) / span
            pixels[x, y] = lerp(TOP, BOTTOM, t)
    return image


def draw_mark(image: Image.Image, size: int) -> None:
    """白色 `❯_` 提示符。

    几何按"整组居中"来定，而不是分别摆两个元素：
      · 先定笔宽 `unit`（画布的 8.5%）；
      · 箭头与光标**共用同一条水平中轴** `axis`，这样看起来是一句话而不是两个图形；
      · 整组的包围盒再水平居中。
    """
    draw = ImageDraw.Draw(image)
    white = (255, 255, 255)

    unit = size * 0.078
    axis = size * 0.50          # 共用中轴
    half = unit / 2

    # ❯：顶点在右，两条等长斜边
    arm = size * 0.155          # 斜边的水平投影
    rise = size * 0.150         # 斜边的垂直投影
    tip_x = size * 0.455
    tail_x = tip_x - arm

    def thick_line(p0, p1):
        draw.line([p0, p1], fill=white, width=int(unit), joint="curve")
        for (px, py) in (p0, p1):
            draw.ellipse([px - half, py - half, px + half, py + half], fill=white)

    thick_line((tail_x, axis - rise), (tip_x, axis))
    thick_line((tip_x, axis), (tail_x, axis + rise))

    # _：与箭头同轴的圆角光标，高度就是一个笔宽
    cursor_left = tip_x + size * 0.075
    cursor_right = cursor_left + size * 0.170
    draw.rounded_rectangle(
        [cursor_left, axis - half, cursor_right, axis + half],
        radius=half * 0.85,
        fill=white,
    )

    # 整组水平居中：包围盒 = [tail_x - half, cursor_right + half]
    left = tail_x - half
    right = cursor_right + half
    shift = (size - (right - left)) / 2 - left
    if abs(shift) > 0.5:
        shifted = Image.new("RGBA", image.size, (0, 0, 0, 0))
        shifted.paste(image, (round(shift), 0))
        image.paste(shifted, (0, 0), shifted)


def main() -> int:
    size = SIZE * SUPERSAMPLE
    image = make_background(size)
    draw_mark(image, size)
    image = image.resize((SIZE, SIZE), Image.LANCZOS)

    if "--preview" in sys.argv:
        preview = image.resize((120, 120), Image.LANCZOS)
        target = ROOT / "docs" / "artifacts" / "screenshots" / "app-icon-120.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        preview.save(target)
        print(f"小尺寸预览：{target.relative_to(ROOT)}")

    ICONSET.mkdir(parents=True, exist_ok=True)
    icon = ICONSET / "AppIcon-1024.png"
    image.save(icon)
    print(f"已写入 {icon.relative_to(ROOT)}（{SIZE}×{SIZE}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
