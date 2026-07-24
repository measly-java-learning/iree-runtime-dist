#!/usr/bin/env bash
# Asset naming. Single source of truth. Source me.
asset_stem()   { printf 'iree-runtime-%s-%s-%s' "$1" "$2" "$3"; }   # <version> <variant> <platform>
tarball_name() { printf '%s.tar.gz' "$(asset_stem "$@")"; }
sha_name()     { printf '%s.sha256' "$(tarball_name "$@")"; }

# Supported platforms. Single source of truth for build-runtime.sh (the
# platform it stamps into manifest.json/BUILDINFO/the tarball name) and
# gen-pin.sh (the platforms it emits URL/SHA variables for). If these ever
# drift apart, gen-pin.sh can reference an asset that was never built.
#
# release.yml's build/verify job matrices thread this through via the setup
# job's `platforms` output (see the `platforms` step in release.yml, which
# sources this file) rather than hard-coding the list a third and fourth
# time -- YAML can't source a shell lib directly, so it goes through a step
# output instead.
PLATFORMS="linux-x86_64 linux-aarch64"
known_platforms() { printf '%s\n' $PLATFORMS; }

# Build-image identity, keyed off the platform token above. The prebuilt
# toolchain container is per-platform (a manylinux_2_28 base exists for each
# arch), so the image tag and its Dockerfile are named by the SAME platform
# string the artifact is -- one token, no drift. Adding a platform to PLATFORMS
# plus dropping in docker/<platform>.Dockerfile is the whole change; the local
# builder (scripts/build-image.sh), release.yml, and warm-build-image.yml all
# derive tag and Dockerfile path from here rather than hard-coding either.
BUILD_IMAGE_REPO="iree-runtime-dist-build"
build_image_tag()  { printf '%s:%s' "$BUILD_IMAGE_REPO" "$1"; }  # <platform>
build_dockerfile() { printf 'docker/%s.Dockerfile' "$1"; }        # <platform>, repo-relative
platforms_json() { # JSON array, for GitHub Actions' fromJson() in a matrix
  python3 -c "import json,sys; print(json.dumps(sys.argv[1].split()))" "$PLATFORMS"
}
