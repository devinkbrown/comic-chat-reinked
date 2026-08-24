# Desktop integration

## Portable release artifacts

The portable release contains a source archive, Windows x86_64 ZIP, Linux
x86_64 and aarch64 tarballs, FreeBSD x86_64 tarball, OpenBSD x86_64 tarball,
and a `SHA256SUMS` manifest. Every archive includes this guide, the top-level
licenses/notices, and the product documentation. Verify the downloaded files
with `sha256sum -c comicchat-*-SHA256SUMS.txt` before extracting.

Linux amd64 and arm64 clients are first-class compile targets:

```sh
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
zig build linux
```

Reinked accepts a `.ccc` conversation or `.ccr` locator as its only command-line
argument. The application opens the document and keeps the normal secure connection
workflow active.

On Windows, run `packaging\install-windows-associations.ps1` from PowerShell inside
the extracted binary package. It registers both formats for the current user and does
not require administrator access.

On Linux or BSD desktops, install `comicchat.desktop` under
`~/.local/share/applications/` and `comicchat-mime.xml` with the desktop's
`xdg-mime` or shared-mime-info tooling. The executable must be on `PATH`.
