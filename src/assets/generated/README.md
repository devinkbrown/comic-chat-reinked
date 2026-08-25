# Generated HD AVB packages

The twenty-two `*-reimagined-hd-v1.avb` files here are native Comic Chat
simple-avatar packages, not PNG previews. Every package contains an icon and
six `AK_NBODIES2` whole-body records: neutral, happy, surprised, angry, sad,
and action. The records preserve the historical `CAvatarSimple::Save` wire
layout and use embedded 24-bit DIBs.

## Source and reproducibility

| Input | SHA-256 |
| --- | --- |
| Inputs | `../../assets/generated/avatar-pose-sheets-v1/<name>/pose-00.png` through `pose-05.png` |
| Input digests | `../../assets/generated/AVB_SOURCE_SHA256SUMS.txt` |
| Runtime output digests | `../../assets/generated/AVB_SHA256SUMS.txt` |

The artwork is an original, project-generated reimagining. It is not a
Microsoft asset and does not alter the provenance record for the legacy AVB
library. The packaging tool is [`tools/package_generated_avb.py`](../../../tools/package_generated_avb.py).
The checked-in input and output SHA-256 values are in the manifests above.
Verify the pose sources from `assets/generated` with `sha256sum -c
AVB_SOURCE_SHA256SUMS.txt`; verify runtime packages from the repository root
with `sha256sum -c assets/generated/AVB_SHA256SUMS.txt`.

## Colored portrait packages

The 22 `*-color-hd-v1.avb` packages (and the deliberately newer
`tiki-color-hd-v2.avb`) are selectable Color variants. Each is rebuilt from
its matching six-pose sheet in `assets/generated/avatar-pose-sheets-v1/`.
The packager keeps the tallest ink y-band in the widest column-run so a
wrap sliver under the heels is not packaged; runtime crop uses the same
rule. Testdata `anna` is not rebuilt here.
Those sheets already carry independent local color (Anna: peach skin, red
tube top, black skirt). The packager keeps that paint; it only transfers
color from `avatar-color-hd-v1/` when a pose is still grayscale. A single
hue wash is never applied. `tiki-color-hd-v2.png` is the Tiki reference
selected for the v2 package. Each package is a native simple-avatar AVB with distinct
neutral, laugh, surprised, angry, sad, and action records, so the same asset
used in the character gallery is also the runtime avatar. Their gallery and
roster icons are derived from the neutral complete figure; the client does
not substitute a separate, potentially cropped head preview.
`COLOR_AVB_SHA256SUMS.txt` records the exact runtime output digests.

Rebuild a color package with:

```sh
python3 tools/package_generated_avb.py \
  --name "Anna Color" --copyright "Generated color pose reconstruction" \
  --portrait-icon --color-reference assets/generated/avatar-color-hd-v1/anna-color-hd-v1.png \
  --output src/assets/generated/anna-color-hd-v1.avb \
  assets/generated/avatar-pose-sheets-v1/anna/pose-{00,01,02,03,04,05}.png
```

Rebuild it after installing the repository's pinned Pillow dependency:

```sh
for source in assets/generated/avatar-pose-sheets-v1/*; do
  name=$(basename "$source")
  python3 tools/package_generated_avb.py \
    --name "${name^} HD" \
    --copyright "ComicChat generated artwork, 2026" \
    --output "src/assets/generated/${name}-reimagined-hd-v1.avb" \
    "$source"/pose-{00,01,02,03,04,05}.png
done
```
