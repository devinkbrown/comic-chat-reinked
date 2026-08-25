#!/bin/sh
# Install the Reinked binary plus freedesktop desktop, MIME, and AppStream
# files for the current user (PREFIX defaults to ~/.local).
set -eu

prefix="${PREFIX:-${HOME}/.local}"
bindir="${prefix}/bin"
applications="${prefix}/share/applications"
mime_packages="${prefix}/share/mime/packages"
metainfo="${prefix}/share/metainfo"

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "${here}/.." && pwd)

pick_binary() {
    if [ "${1:-}" != "" ] && [ -f "$1" ]; then
        printf '%s\n' "$1"
        return
    fi
    if [ -f "${root}/reinked" ]; then
        printf '%s\n' "${root}/reinked"
        return
    fi
    if [ -f "${root}/zig-out/bin/reinked" ]; then
        printf '%s\n' "${root}/zig-out/bin/reinked"
        return
    fi
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            if [ -f "${root}/zig-out/bin/reinked-linux-amd64" ]; then
                printf '%s\n' "${root}/zig-out/bin/reinked-linux-amd64"
                return
            fi
            ;;
        aarch64|arm64)
            if [ -f "${root}/zig-out/bin/reinked-linux-arm64" ]; then
                printf '%s\n' "${root}/zig-out/bin/reinked-linux-arm64"
                return
            fi
            ;;
    esac
    printf 'install-linux.sh: no reinked binary found. Build one first or pass its path.\n' >&2
    exit 1
}

binary=$(pick_binary "${1:-}")

mkdir -p "$bindir" "$applications" "$mime_packages" "$metainfo"
install -m755 "$binary" "${bindir}/reinked"
install -m644 "${here}/comicchat.desktop" "${applications}/comicchat.desktop"
install -m644 "${here}/comicchat-mime.xml" "${mime_packages}/comicchat.xml"
install -m644 "${here}/com.reinked.comicchat.metainfo.xml" \
    "${metainfo}/com.reinked.comicchat.metainfo.xml"

if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database "${prefix}/share/mime"
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$applications"
fi

printf 'Installed reinked to %s\n' "${bindir}/reinked"
printf 'Desktop entry: %s\n' "${applications}/comicchat.desktop"
