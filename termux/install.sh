#!/data/data/com.termux/files/usr/bin/sh
# Standalone lark-cli installer for Termux (no Emacs needed).
# The Elisp path is M-x lark-org-cli-install inside lark-org; this
# script does the same three steps in POSIX sh: download, sha256
# verify against the release checksums.txt, install one static
# binary.  Usage:  sh termux/install.sh [version]   (default 1.0.100)
set -eu

VER=${1:-1.0.100}
ARCH=$(uname -m)
case "$ARCH" in
	aarch64|armv8a) ASSET_ARCH=arm64 ;;
	x86_64) ASSET_ARCH=amd64 ;;
	*) echo "lark-cli ships no $ARCH build" >&2; exit 1 ;;
esac

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
BASE="https://github.com/larksuite/cli/releases/download/v${VER}"
ASSET="lark-cli-${VER}-linux-${ASSET_ARCH}.tar.gz"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading ${ASSET}"
curl -fsSL "${BASE}/${ASSET}" -o "${TMP}/lark-cli.tar.gz"
curl -fsSL "${BASE}/checksums.txt" -o "${TMP}/checksums.txt"

echo "==> verifying sha256"
grep " ${ASSET}\$" "${TMP}/checksums.txt" | (cd "$TMP" && sha256sum -c -)

tar -xf "${TMP}/lark-cli.tar.gz" -C "$TMP"
install -Dm755 "${TMP}/lark-cli" "${PREFIX}/bin/lark-cli"

echo "==> lark-cli ${VER} installed to ${PREFIX}/bin/lark-cli"
echo "    next: lark-cli auth login --recommend"
