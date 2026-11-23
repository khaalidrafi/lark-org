# lark-cli for Termux: repack of the official static Go binary.
#
# Upstream: https://github.com/larksuite/cli (MIT).
# The release binaries are static (no PT_INTERP -- verified with
# readelf), so a plain repack into $PREFIX/bin works on aarch64 and
# x86_64: no glibc, no patchelf, no node.
#
# Bumping: change TERMUX_PKG_VERSION and both _LARK_SHA256 values
# from the release's checksums.txt.
TERMUX_PKG_HOMEPAGE=https://github.com/larksuite/cli
TERMUX_PKG_DESCRIPTION="Official Lark/Feishu CLI tool for humans and AI agents"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_VERSION=1.0.100
TERMUX_PKG_DEPENDS=""

case "${TERMUX_ARCH}" in
	aarch64)
		_LARK_ARCH=arm64
		_LARK_SHA256=166e95ffaec34f82123f50316480250329884c09e71a6f92313047e2c5c3fa5d
		;;
	x86_64)
		_LARK_ARCH=amd64
		_LARK_SHA256=cd7363f731c9e5dd2becd909837922cffea8aad229d581a84eb13c6aa0ce6808
		;;
	*)
		termux_error_exit "lark-cli ships no ${TERMUX_ARCH} build (upstream: arm64, amd64, riscv64)"
		;;
esac

TERMUX_PKG_SRCURL="https://github.com/larksuite/cli/releases/download/v${TERMUX_PKG_VERSION}/lark-cli-${TERMUX_PKG_VERSION}-linux-${_LARK_ARCH}.tar.gz"
TERMUX_PKG_SHA256="${_LARK_SHA256}"

# Binary repack: nothing to configure or build.
termux_step_configure() {
	:
}

termux_step_make() {
	:
}

termux_step_make_install() {
	# The release tarball is flat: lark-cli, README.md, CHANGELOG.md, LICENSE.
	install -Dm755 -T "${TERMUX_PKG_SRCDIR}/lark-cli" \
		"${TERMUX_PREFIX}/bin/lark-cli"
	install -Dm644 -T "${TERMUX_PKG_SRCDIR}/LICENSE" \
		"${TERMUX_PREFIX}/share/doc/lark-cli/LICENSE"
	install -Dm644 -T "${TERMUX_PKG_SRCDIR}/README.md" \
		"${TERMUX_PREFIX}/share/doc/lark-cli/README.md"
}
