# Build container for the `linux-x86_64` platform. The filename encodes the
# platform token (scripts/lib/naming.sh) so the image tag, its Dockerfile, and
# the artifact platform stay one name; an aarch64 platform would add a sibling
# docker/linux-aarch64.Dockerfile (manylinux_2_28_aarch64 base) with no change
# to how tag/Dockerfile are resolved.
#
# Thin local specialization of the manylinux_2_28 build container with the
# recipe's toolchain (clang/lld/ninja) preinstalled, so every build/verify
# invocation stops paying a `dnf install` tax.
#
# Pinned to a dated tag, not `latest` -- this image is part of the build
# environment that manifest.json attests to (glibc_build: 2.28), so a
# floating base would make builds silently non-reproducible.
FROM quay.io/pypa/manylinux_2_28_x86_64:2026.06.04-1

# Pinned to the exact NEVRAs recorded by Task 4 (clang/lld 21.1.8,
# ninja-build 1.8.2) rather than bare package names, so a repo update to a
# newer default module stream cannot silently change the toolchain this
# image bakes in. If AlmaLinux/EPEL ever retire these specific builds from
# the mirror, this RUN line starts failing loudly (dnf can't resolve the
# NEVRA) instead of silently drifting -- re-resolve with
# `dnf list --showduplicates clang lld ninja-build` and update the pins.
#
# patchelf is deliberately NOT installed here: the base image already ships
# patchelf 0.17.2 at /usr/local/bin, which is ahead of the dnf package
# (0.12-1.el8) on PATH and shadows it completely, so a dnf-installed
# patchelf would be dead weight -- see scripts/relocatability.sh's
# `command -v patchelf` check, which resolves to /usr/local/bin/patchelf
# either way.
RUN dnf install -y \
      clang-21.1.8-1.module_el8.10.0+4172+b6b13d75 \
      lld-21.1.8-1.module_el8.10.0+4172+b6b13d75 \
      ninja-build-1.8.2-1.el8 \
    && dnf clean all
