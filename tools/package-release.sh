#!/usr/bin/env bash
# Build the complete reproducible ComicChat release set: native binaries for
# Windows x86_64 plus Linux amd64/arm64 and the BSD x86_64 pair, one
# self-contained source archive, and one checksum manifest.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=${1:-$(git -C "$repo_root" describe --tags --always --dirty)}
output_dir=${OUTPUT_DIR:-"$repo_root/dist"}
temp_root=${TMPDIR:-/tmp}
stage_dir=$(mktemp -d "$temp_root/comicchat-release.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT
source_epoch=${SOURCE_DATE_EPOCH:-$(git -C "$repo_root" show -s --format=%ct HEAD)}

if [[ ! "$version" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'Invalid release version: %s\n' "$version" >&2
    exit 2
fi

if ! git -C "$repo_root" diff --quiet || ! git -C "$repo_root" diff --cached --quiet; then
    printf 'Refusing to package dirty tracked source. Commit or stash it first.\n' >&2
    exit 2
fi

normalize_tree() {
    find "$1" -exec touch -h -d "@$source_epoch" {} +
}

assert_release_clean() {
    local tree=$1
    local matches

    matches=$(grep -IRniE --exclude='package-release.sh' \
        --exclude='*.avb' --exclude='*.bgb' --exclude='*.bin' \
        --exclude='*.bmp' --exclude='*.png' \
        'SPDX-FileCopyrightText:.*<[^>]+>|/home/[[:alnum:]_.-]+' \
        "$tree" || true)
    if [[ -n "$matches" ]]; then
        printf 'Personal identifier found in release tree:\n%s\n' "$matches" >&2
        exit 3
    fi

    matches=$(find "$tree" -type f \( \
        -iname '*.pem' -o -iname '*.key' -o -iname '*.crt' -o \
        -iname '*.cer' -o -iname '*.p12' -o -iname '*.pfx' -o \
        -iname '*.keystore' -o -iname 'id_rsa*' -o -iname 'id_ed25519*' \
        \) -print)
    if [[ -n "$matches" ]]; then
        printf 'Certificate or private-key file found in release tree:\n%s\n' "$matches" >&2
        exit 3
    fi
}

sanitize_release_text() {
    local tree=$1 file
    while IFS= read -r -d '' file; do
        grep -Iq . "$file" || continue
        sed -i -E \
            -e 's#^// SPDX-FileCopyrightText:.*$#// SPDX-FileCopyrightText: 2026 Onyx contributors#' \
            -e 's#/home/[[:alnum:]_.-]+#/path/to#g' \
            "$file"
    done < <(find "$tree" -type f -print0)
}

write_tar_gz() {
    local parent=$1 basename=$2 destination=$3
    tar --sort=name --mtime="@$source_epoch" --owner=0 --group=0 --numeric-owner \
        -C "$parent" -cf - "$basename" | gzip -n > "$destination"
}

package_target() {
    local target=$1 platform=$2 executable=$3 archive=$4 format=$5
    local prefix="$stage_dir/$platform"
    local package_dir="$prefix/reinked-$version-$platform"

    (cd "$repo_root" && zig build -Dtarget="$target" -Doptimize=ReleaseSafe -Dstrip=true --prefix "$prefix")
    mkdir -p "$package_dir"
    cp "$prefix/bin/$executable" "$package_dir/"
    cp "$repo_root/README.md" "$repo_root/LICENSE" "$repo_root/NOTICE" "$package_dir/"
    cp "$repo_root/LICENSES/MIT.txt" "$repo_root/src/render/COMIC_NEUE_LICENSE.txt" "$package_dir/"
    cp "$repo_root/src/render/LIBERATION_SANS_LICENSE.txt" "$package_dir/"
    cp -R "$repo_root/docs" "$package_dir/docs"
    cp -R "$repo_root/packaging" "$package_dir/packaging"
    assert_release_clean "$package_dir"
    normalize_tree "$package_dir"

    if [[ "$format" == zip ]]; then
        (cd "$prefix" && 7z a -tzip -bd -mx=9 -mtc=off -mta=off -mtm=off \
            "$output_dir/$archive" "$(basename "$package_dir")")
    else
        write_tar_gz "$prefix" "$(basename "$package_dir")" "$output_dir/$archive"
    fi
}

package_source() {
    local source_basename="reinked-$version-source"
    local source_dir="$stage_dir/source/$source_basename"
    local pinned_onyx
    local -a onyx_files
    pinned_onyx=$(git -C "$repo_root" rev-parse HEAD:third_party/onyx-server)
    mapfile -t onyx_files < "$repo_root/tools/onyx-tls-sources.txt"

    mkdir -p "$source_dir"
    git -C "$repo_root" archive HEAD | tar -x -C "$source_dir"
    rm -f "$source_dir/.gitmodules"
    rm -rf "$source_dir/legacy"
    mkdir -p "$source_dir/third_party/onyx-server"
    git -C "$repo_root/third_party/onyx-server" archive "$pinned_onyx" \
        LICENSE "${onyx_files[@]}" | \
        tar -x -C "$source_dir/third_party/onyx-server"
    printf '%s\n' "$pinned_onyx" > "$source_dir/third_party/onyx-server/REVISION"
    sanitize_release_text "$source_dir"
    assert_release_clean "$source_dir"
    normalize_tree "$source_dir"
    write_tar_gz "$stage_dir/source" "$source_basename" \
        "$output_dir/reinked-$version-source.tar.gz"
}

mkdir -p "$output_dir"
rm -f "$output_dir"/reinked-"$version"-windows-x86_64.zip \
      "$output_dir"/reinked-"$version"-linux-x86_64.tar.gz \
      "$output_dir"/reinked-"$version"-linux-aarch64.tar.gz \
      "$output_dir"/reinked-"$version"-freebsd-x86_64.tar.gz \
      "$output_dir"/reinked-"$version"-openbsd-x86_64.tar.gz \
      "$output_dir"/reinked-"$version"-source.tar.gz \
      "$output_dir"/reinked-"$version"-SHA256SUMS.txt

package_target x86_64-windows windows-x86_64 reinked.exe \
    "reinked-$version-windows-x86_64.zip" zip
package_target x86_64-linux linux-x86_64 reinked \
    "reinked-$version-linux-x86_64.tar.gz" tar.gz
package_target aarch64-linux linux-aarch64 reinked \
    "reinked-$version-linux-aarch64.tar.gz" tar.gz
package_target x86_64-freebsd freebsd-x86_64 reinked \
    "reinked-$version-freebsd-x86_64.tar.gz" tar.gz
package_target x86_64-openbsd openbsd-x86_64 reinked \
    "reinked-$version-openbsd-x86_64.tar.gz" tar.gz
package_source

(cd "$output_dir" && sha256sum \
    "reinked-$version-windows-x86_64.zip" \
    "reinked-$version-linux-x86_64.tar.gz" \
    "reinked-$version-linux-aarch64.tar.gz" \
    "reinked-$version-freebsd-x86_64.tar.gz" \
    "reinked-$version-openbsd-x86_64.tar.gz" \
    "reinked-$version-source.tar.gz" \
    > "reinked-$version-SHA256SUMS.txt")

printf 'Packages written to %s\n' "$output_dir"
