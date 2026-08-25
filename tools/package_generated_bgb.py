#!/usr/bin/env python3
"""Package project-generated backdrop art as a native Comic Chat BGB."""

from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

from PIL import Image


MAGIC = 0x8181
BACKGROUND = 3
VERSION = 2
AK_NAME = 1
AK_STARTDATA = 6
AK_ENDDATA = 7
AK_BACKDROP = 258
AK_COPYRIGHT = 259
AIF_DIB = 0
AIP_NOPALETTE = 0


def u16(value: int) -> bytes:
    return struct.pack("<H", value)


def u32(value: int) -> bytes:
    return struct.pack("<I", value)


def variable_record(tag: int, payload: bytes) -> bytes:
    return u16(tag) + u16(len(payload)) + payload


def _is_paper(pixel: tuple[int, ...]) -> bool:
    """Sheet gutter / near-white matte. Authored sky and wood stay ink."""
    red, green, blue = pixel[:3]
    if red >= 245 and green >= 245 and blue >= 245:
        return True
    return min(red, green, blue) >= 228 and max(red, green, blue) - min(red, green, blue) < 18


def trim_paper_matte(image: Image.Image, threshold: float = 0.90) -> Image.Image:
    """Drop sheet gutters that would package as room paper bleed.

    Color tiles are cropped from a comic sheet. A 4–6px white matte around
    the panel becomes a paper band in the 315×315 BGB and shows in the
    background dialog. Trim edge rows/cols that are almost all paper; keep
    authored white windows and the black panel frame.
    """
    pixels = image.load()
    width, height = image.size

    def row_paper(y: int) -> float:
        return sum(1 for x in range(width) if _is_paper(pixels[x, y])) / width

    def col_paper(x: int) -> float:
        return sum(1 for y in range(height) if _is_paper(pixels[x, y])) / height

    top = 0
    while top < height - 8 and row_paper(top) >= threshold:
        top += 1
    bottom = height
    while bottom > top + 8 and row_paper(bottom - 1) >= threshold:
        bottom -= 1
    left = 0
    while left < width - 8 and col_paper(left) >= threshold:
        left += 1
    right = width
    while right > left + 8 and col_paper(right - 1) >= threshold:
        right -= 1
    if top == 0 and left == 0 and bottom == height and right == width:
        return image
    return image.crop((left, top, right, bottom))


def _is_ink(pixel: tuple[int, ...]) -> bool:
    return max(pixel[:3]) < 45


def _frame_bands(fracs: list[float], threshold: float = 0.80) -> list[tuple[int, int]]:
    bands: list[tuple[int, int]] = []
    index = 0
    while index < len(fracs):
        if fracs[index] < threshold:
            index += 1
            continue
        start = index
        while index < len(fracs) and fracs[index] >= threshold:
            index += 1
        bands.append((start, index))
    return bands


def _row_frac(image: Image.Image, predicate) -> list[float]:
    pixels = image.load()
    width, height = image.size
    return [
        sum(1 for x in range(width) if predicate(pixels[x, y])) / width
        for y in range(height)
    ]


def _col_frac(image: Image.Image, predicate) -> list[float]:
    pixels = image.load()
    width, height = image.size
    return [
        sum(1 for y in range(height) if predicate(pixels[x, y])) / height
        for x in range(width)
    ]


def _thin_edge_bands(fracs: list[float], threshold: float = 0.85, max_len: int = 4) -> list[tuple[int, int]]:
    """Full-width ink rules only. Dark night sky is a long band, not a frame."""
    return [band for band in _frame_bands(fracs, threshold) if band[1] - band[0] <= max_len]


def crop_panel_interior(image: Image.Image) -> Image.Image:
    """Drop the sheet's black frame and the next-panel sliver under it.

    Color tiles are cut from a comic sheet. After the paper gutter is gone,
    a 2px ink frame still sits at the panel edge, and 10–15px of the next
    tile (palm, sky, gutter) still packages under the bottom rule. Crop to
    the room inside that frame. A dark rooftop sky is not a frame.
    """
    paper_rows = _row_frac(image, _is_paper)
    ink_rows = _row_frac(image, _is_ink)
    ink_cols = _col_frac(image, _is_ink)
    width, height = image.size
    top, bottom = 0, height
    left, right = 0, width
    found = False

    paper_bands = [band for band in _frame_bands(paper_rows, 0.70) if band[1] - band[0] >= 4]
    for start, _end in paper_bands:
        if start <= 20:
            continue
        bottom = start
        cursor = start - 1
        while cursor >= 0 and ink_rows[cursor] >= 0.80:
            bottom = cursor
            cursor -= 1
        found = True
        break

    thin_rows = _thin_edge_bands(ink_rows)
    if thin_rows and thin_rows[0][0] <= 4:
        top = thin_rows[0][1]
        found = True
    if not paper_bands and thin_rows and thin_rows[-1][1] >= height - 6:
        bottom = thin_rows[-1][0]
        found = True

    thin_cols = _thin_edge_bands(ink_cols)
    if thin_cols and thin_cols[0][0] <= 4:
        left = thin_cols[0][1]
        found = True
    if thin_cols and thin_cols[-1][1] >= width - 6:
        right = thin_cols[-1][0]
        found = True

    if not found:
        return image
    top = min(height - 8, top)
    left = min(width - 8, left)
    bottom = max(top + 8, bottom)
    right = max(left + 8, right)
    if right - left < 200 or bottom - top < 200:
        return image
    return image.crop((left, top, right, bottom))


def normalize_room(image: Image.Image) -> Image.Image:
    return crop_panel_interior(trim_paper_matte(image.convert("RGB"))).resize(
        (315, 315), Image.Resampling.LANCZOS
    )


def bmp24(image: Image.Image) -> bytes:
    image = image.convert("RGB")
    width, height = image.size
    stride = ((width * 3 + 3) // 4) * 4
    pixels = bytearray(stride * height)
    for y in range(height):
        dest = (height - 1 - y) * stride
        for x in range(width):
            red, green, blue = image.getpixel((x, y))
            offset = dest + x * 3
            pixels[offset : offset + 3] = bytes((blue, green, red))
    pixel_offset = 14 + 40
    size = pixel_offset + len(pixels)
    return b"BM" + u32(size) + u16(0) + u16(0) + u32(pixel_offset) + u32(40) + struct.pack(
        "<iiHHIIiiII", width, height, 1, 24, 0, len(pixels), 0, 0, 0, 0
    ) + pixels


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--copyright", required=True, dest="copyright_text")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("image", type=Path)
    args = parser.parse_args()
    image = normalize_room(Image.open(args.image))
    dib = bmp24(image)
    name_record = u16(AK_NAME) + args.name.encode("utf-8") + b"\0"
    copyright_record = variable_record(AK_COPYRIGHT, args.copyright_text.encode("utf-8") + b"\0")
    data_offset = 6 + len(name_record) + len(copyright_record) + 2 + 2 + 6 + 2
    data = bytearray(u16(MAGIC) + u16(BACKGROUND) + u16(VERSION))
    data += name_record + copyright_record
    data += variable_record(AK_BACKDROP, u32(data_offset) + bytes((AIF_DIB, AIP_NOPALETTE)))
    data += u16(AK_STARTDATA) + dib + u16(AK_ENDDATA)
    if len(data) != data_offset + len(dib) + 2:
        raise AssertionError("BGB metadata size drift")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(f"wrote {args.output} ({len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()})")


if __name__ == "__main__":
    main()
