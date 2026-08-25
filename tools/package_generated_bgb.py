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
    image = trim_paper_matte(Image.open(args.image).convert("RGB")).resize((315, 315), Image.Resampling.LANCZOS)
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
