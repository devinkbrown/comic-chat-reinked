# Desktop integration

## Portable release artifacts

The portable release contains a source archive, Windows x86_64 ZIP, Linux
x86_64 and aarch64 tarballs, FreeBSD x86_64 tarball, OpenBSD x86_64 tarball,
and a `SHA256SUMS` manifest. Every archive includes this guide, the top-level
licenses/notices, and the product documentation. Verify the downloaded files
with `sha256sum -c comicchat-*-SHA256SUMS.txt` before extracting.

Linux amd64 and arm64 clients are first-class compile targets:

```sh
git submodule update --init --recursive
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
zig build linux
```

`zig build linux` installs `reinked-linux-amd64` and `reinked-linux-arm64`
without changing the default `zig-out/bin/reinked` name. Release-shaped
binaries match `tools/package-release.sh`:

```sh
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe -Dstrip=true
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe -Dstrip=true
```

The Linux tarballs already include this `packaging/` directory. Copy the
architecture that matches the machine (`linux-x86_64` or `linux-aarch64`).

Reinked accepts a `.ccc` conversation or `.ccr` locator as its only command-line
argument. The application opens the document and keeps the normal secure connection
workflow active.

## Linux install

Put the executable on `PATH` as `reinked` (the `.desktop` file calls that
name). `StartupWMClass=comicchat` matches the native X11 `WM_CLASS` and
Wayland `xdg_toplevel` app id so a panel groups the window with the launcher.

The helper installs the binary, desktop entry, MIME package, and AppStream
metainfo under `PREFIX` (default `~/.local`):

```sh
./packaging/install-linux.sh
# or
./packaging/install-linux.sh /path/to/reinked
PREFIX=/usr/local ./packaging/install-linux.sh
```

Manual copy is the same layout:

```sh
install -Dm755 reinked ~/.local/bin/reinked
install -Dm644 packaging/comicchat.desktop \
    ~/.local/share/applications/comicchat.desktop
install -Dm644 packaging/comicchat-mime.xml \
    ~/.local/share/mime/packages/comicchat.xml
install -Dm644 packaging/com.reinked.comicchat.metainfo.xml \
    ~/.local/share/metainfo/com.reinked.comicchat.metainfo.xml
update-mime-database ~/.local/share/mime
update-desktop-database ~/.local/share/applications
```

Compose sequences load from `XCOMPOSEFILE`, then `~/.XCompose`, then the
system locale table (`/usr/share/X11/locale/*/Compose`). Files and include
depth are capped; missing files keep the built-in dead-key / Multi_key set.

A nonempty `WAYLAND_DISPLAY` selects the Wayland backend. There is no X11
fallback if that socket is missing. For X11 or XWayland:

```sh
env -u WAYLAND_DISPLAY reinked
```

On Windows, run `packaging\install-windows-associations.ps1` from PowerShell inside
the extracted binary package. It registers both formats for the current user and does
not require administrator access.

On BSD desktops, the same `.desktop` and MIME files work with `xdg-mime` or
shared-mime-info once the executable is on `PATH`.
