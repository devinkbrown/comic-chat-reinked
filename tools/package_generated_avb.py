#!/usr/bin/env python3
"""Package generated Comic Chat avatar pose art as a native simple-avatar AVB.

The file structure is a direct, intentionally small implementation of the
historical CAvatarSimple::Save path: AVATARHEADER, AK_ICON_NEW,
AK_NBODIES2, AK_STARTDATA, embedded DIBs, then AK_ENDDATA.  White pixels are
kept white because Comic Chat's CBodySingle uses SRCAND; on a comic panel they
leave the destination unchanged, which is the same practical matte used by
the original simple-avatar art.
"""

from __future__ import annotations

import argparse
import colorsys
import hashlib
import struct
from pathlib import Path

from PIL import Image, ImageChops


MAGIC = 0x8181
SIMPLE_AVATAR = 1
VERSION = 2
AK_NAME = 1
AK_NBODIES2 = 12
AK_STARTDATA = 6
AK_ENDDATA = 7
AK_ICON_NEW = 256
AK_COPYRIGHT = 259
AIF_DIB = 0
AIP_NOPALETTE = 0

# The authored order is also the simple-avatar gesture ordinal used by
# CAvatarSimple when an old client asks for a UDI pose.
POSES = (
    ("neutral", 9),
    ("laugh", 8),
    ("surprised", 7),
    ("angry", 2),
    ("sad", 4),
    ("action", 10),
)


def u16(value: int) -> bytes:
    return struct.pack("<H", value)


def u32(value: int) -> bytes:
    return struct.pack("<I", value)


def variable_record(tag: int, payload: bytes) -> bytes:
    if len(payload) > 0xFFFF:
        raise ValueError(f"record {tag} is too large")
    return u16(tag) + u16(len(payload)) + payload


def _column_has_ink(pixels, width: int, height: int, x: int) -> bool:
    for y in range(height):
        red, green, blue = pixels[x, y]
        if red < 245 or green < 245 or blue < 245:
            return True
    return False


def largest_ink_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    """Widest non-white column-run. Ignores a wrap sliver on the right."""
    pixels = image.load()
    width, height = image.size
    best: tuple[int, int] | None = None
    x = 0
    while x < width:
        if not _column_has_ink(pixels, width, height, x):
            x += 1
            continue
        x1 = x + 1
        while x1 < width and _column_has_ink(pixels, width, height, x1):
            x1 += 1
        if best is None or (x1 - x) > (best[1] - best[0]):
            best = (x, x1)
        x = x1
    if best is None:
        raise ValueError("image contains no visible pose")
    x0, x1 = best
    top, bottom = height, 0
    for y in range(height):
        for col in range(x0, x1):
            red, green, blue = pixels[col, y]
            if red < 245 or green < 245 or blue < 245:
                top = min(top, y)
                bottom = max(bottom, y + 1)
    if top >= bottom:
        raise ValueError("image contains no visible pose")

    # A wrap sliver can sit in the same columns as the figure, far below the
    # heels. Keep the tallest y-band and allow a 2-row hole so a shoe strap
    # is not split off. Runtime `largestPaperInkRun` uses the same rule.
    best_y0, best_y1 = top, top
    band_start: int | None = None
    last_ink = top
    for y in range(top, bottom + 1):
        row_ink = False
        if y < bottom:
            for col in range(x0, x1):
                red, green, blue = pixels[col, y]
                if red < 245 or green < 245 or blue < 245:
                    row_ink = True
                    break
        if row_ink:
            if band_start is None:
                band_start = y
            last_ink = y
            continue
        if band_start is not None:
            if y < bottom and y <= last_ink + 2:
                continue
            end = last_ink + 1
            if end > band_start and end - band_start > best_y1 - best_y0:
                best_y0, best_y1 = band_start, end
            band_start = None
    if best_y1 <= best_y0:
        return (x0, top, x1, bottom)
    return (x0, best_y0, x1, best_y1)


def normalize_pose(path: Path) -> Image.Image:
    """Crop a nearly-white generated card and return a compact white-matte pose."""
    source = Image.open(path).convert("RGB")
    # The generator's card background varies a few values around white.  Map
    # it to pure white so SRCAND does not leave a visible rectangle.
    pixels = source.load()
    for y in range(source.height):
        for x in range(source.width):
            red, green, blue = pixels[x, y]
            if red >= 245 and green >= 245 and blue >= 245:
                pixels[x, y] = (255, 255, 255)

    left, top, right, bottom = largest_ink_bbox(source)
    pad = 12
    crop = source.crop((max(0, left - pad), max(0, top - pad), min(source.width, right + pad), min(source.height, bottom + pad)))
    crop.thumbnail((210, 260), Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", (240, 280), "white")
    canvas.paste(crop, ((canvas.width - crop.width) // 2, canvas.height - crop.height - 6))
    return canvas


def _chromatic_hue_bins(image: Image.Image) -> dict[int, int]:
    bins: dict[int, int] = {}
    for red, green, blue in image.get_flattened_data():
        if red >= 245 and green >= 245 and blue >= 245:
            continue
        hue, saturation, value = colorsys.rgb_to_hsv(red / 255, green / 255, blue / 255)
        if value < 0.16 or saturation < 0.14:
            continue
        bucket = int(hue * 12) % 12
        bins[bucket] = bins.get(bucket, 0) + 1
    return bins


def has_local_color(image: Image.Image) -> bool:
    """True when the pose already has independently painted regions."""
    bins = _chromatic_hue_bins(image)
    chromatic = sum(bins.values())
    if chromatic < 200:
        return False
    strong = sum(1 for count in bins.values() if count >= max(80, chromatic * 0.03))
    return strong >= 2


def _silhouette_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    inverted = ImageChops.invert(image.convert("RGB"))
    bbox = inverted.getbbox()
    if bbox is None:
        raise ValueError("image contains no visible silhouette")
    return bbox


def transfer_local_color(pose: Image.Image, reference: Path) -> Image.Image:
    """Copy the reference's per-region hues onto a grayscale pose.

    Aligns silhouettes, then keeps the pose's ink and luminance so shading
    stays put. This is not a one-hue wash: a red top and peach skin stay
    different colors.
    """
    ref = Image.open(reference).convert("RGB")
    pose_box = _silhouette_bbox(pose)
    ref_box = _silhouette_bbox(ref)
    pose_w = max(1, pose_box[2] - pose_box[0])
    pose_h = max(1, pose_box[3] - pose_box[1])
    ref_w = max(1, ref_box[2] - ref_box[0])
    ref_h = max(1, ref_box[3] - ref_box[1])
    ref_px = ref.load()
    result = pose.copy()
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue = pixels[x, y]
            if red >= 245 and green >= 245 and blue >= 245:
                continue
            value = (red * 0.2126 + green * 0.7152 + blue * 0.0722) / 255.0
            if value < 0.22:
                ink = int(18 + value * 75)
                pixels[x, y] = (ink, ink, ink)
                continue
            nx = min(1.0, max(0.0, (x - pose_box[0]) / pose_w))
            ny = min(1.0, max(0.0, (y - pose_box[1]) / pose_h))
            rx = min(ref.width - 1, ref_box[0] + int(nx * (ref_w - 1)))
            ry = min(ref.height - 1, ref_box[1] + int(ny * (ref_h - 1)))
            sample = ref_px[rx, ry]
            hue, saturation, _ = colorsys.rgb_to_hsv(sample[0] / 255, sample[1] / 255, sample[2] / 255)
            if saturation < 0.08:
                continue
            colored = colorsys.hsv_to_rgb(hue, min(0.85, saturation), min(0.94, value * 1.04))
            pixels[x, y] = tuple(round(channel * 255) for channel in colored)
    return result


def colorize_pose(pose: Image.Image, reference: Path) -> Image.Image:
    """Keep authored local color. Only paint grayscale poses from the reference."""
    if has_local_color(pose):
        return pose
    return transfer_local_color(pose, reference)


def bmp24(image: Image.Image) -> bytes:
    """Return a bottom-up BI_RGB BMP stream accepted by CAvatarDIB::Load."""
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
    file_header = b"BM" + u32(size) + u16(0) + u16(0) + u32(pixel_offset)
    info_header = u32(40) + struct.pack("<iiHHIIiiII", width, height, 1, 24, 0, len(pixels), 0, 0, 0, 0)
    return file_header + info_header + pixels


def build(name: str, copyright_text: str, pose_paths: list[Path], portrait_icon: bool = False, color_reference: Path | None = None) -> bytes:
    if len(pose_paths) != len(POSES):
        raise ValueError(f"expected {len(POSES)} pose PNGs")
    normalized_poses = [normalize_pose(path) for path in pose_paths]
    if color_reference is not None:
        normalized_poses = [colorize_pose(pose, color_reference) for pose in normalized_poses]
    pose_bmps = [bmp24(pose) for pose in normalized_poses]
    icon_source = normalized_poses[0]
    if portrait_icon:
        # Gallery and roster icons need a readable face at 64px. Keep the
        # upper body while the pose records below retain the complete figure.
        # Crop to the actual visible silhouette rather than the source canvas:
        # narrow figures such as Xeno otherwise read as a tiny full body.
        silhouette = ImageChops.invert(icon_source)
        left, top, right, bottom = silhouette.getbbox() or (0, 0, icon_source.width, icon_source.height)
        portrait_bottom = min(bottom, top + max(64, (bottom - top) * 3 // 5))
        pad = 8
        icon_source = icon_source.crop((max(0, left - pad), max(0, top - pad), min(icon_source.width, right + pad), min(icon_source.height, portrait_bottom + pad)))
        icon_source.thumbnail((58, 58), Image.Resampling.LANCZOS)
        icon = Image.new("RGB", (64, 64), "white")
        icon.paste(icon_source, ((64 - icon_source.width) // 2, (64 - icon_source.height) // 2))
    else:
        icon = icon_source.resize((64, 64), Image.Resampling.LANCZOS)
    icon_bmp = bmp24(icon)

    name_record = u16(AK_NAME) + name.encode("utf-8") + b"\0"
    copyright_record = variable_record(AK_COPYRIGHT, copyright_text.encode("utf-8") + b"\0")
    icon_record_size = 2 + 2 + 6
    body_table_size = 2 + 2 + len(POSES) * 25
    data_start = 6 + len(name_record) + len(copyright_record) + icon_record_size + body_table_size + 2
    icon_offset = data_start
    offsets: list[int] = []
    cursor = icon_offset + len(icon_bmp)
    for bmp in pose_bmps:
        offsets.append(cursor)
        cursor += len(bmp)

    result = bytearray()
    result += u16(MAGIC) + u16(SIMPLE_AVATAR) + u16(VERSION)
    result += name_record
    result += copyright_record
    result += variable_record(AK_ICON_NEW, u32(icon_offset) + bytes((AIF_DIB, AIP_NOPALETTE)))
    result += u16(AK_NBODIES2) + u16(len(POSES))
    for offset, (_, emotion) in zip(offsets, POSES):
        # AVATARBODYDATA::newdata: three offsets, emotion, intensity, face
        # point, three AIF_DIB bytes, three AIP_NOPALETTE bytes.
        result += u32(offset) + u32(0) + u32(0)
        result += u16(emotion) + bytes((0,)) + struct.pack("<hh", 120, 60)
        result += bytes((AIF_DIB, AIF_DIB, AIF_DIB, AIP_NOPALETTE, AIP_NOPALETTE, AIP_NOPALETTE))
    result += u16(AK_STARTDATA)
    if len(result) != data_start:
        raise AssertionError(f"metadata size drift: {len(result)} != {data_start}")
    result += icon_bmp
    result += b"".join(pose_bmps)
    result += u16(AK_ENDDATA)
    return bytes(result)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--copyright", required=True, dest="copyright_text")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--portrait-icon", action="store_true", help="crop the icon to a readable head-and-shoulders portrait")
    parser.add_argument("--color-reference", type=Path, help="paint grayscale poses from this portrait's local colors; already-colored poses are kept")
    parser.add_argument("poses", nargs=len(POSES), type=Path, metavar="POSE")
    args = parser.parse_args()
    for pose in args.poses:
        if not pose.is_file():
            parser.error(f"pose file not found: {pose}")
    if args.color_reference is not None and not args.color_reference.is_file():
        parser.error(f"color reference not found: {args.color_reference}")
    data = build(args.name, args.copyright_text, args.poses, args.portrait_icon, args.color_reference)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(f"wrote {args.output} ({len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()})")


if __name__ == "__main__":
    main()
