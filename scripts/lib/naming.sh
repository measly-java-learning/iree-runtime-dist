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
PLATFORMS="linux-x86_64 linux-aarch64 windows-x86_64"
known_platforms() { printf '%s\n' $PLATFORMS; }

# How a platform gets its toolchain. NOT every platform is containerised.
#
#   container - Linux. The toolchain comes from docker/<platform>.Dockerfile,
#               which pins a known-old glibc and the clang/lld/ninja NEVRAs and
#               is the single source of truth for the glibc_build value
#               manifest.json attests to.
#   runner    - Windows. There is no Dockerfile. The toolchain comes from a
#               PINNED GitHub runner image (windows-2022, never windows-latest)
#               plus a VS dev-shell activation. A Windows container would fix
#               none of the Windows-specific problems, and pinning the label is
#               the analog of pinning NEVRAs: msvc_toolset is attested
#               provenance and must not drift silently.
platform_toolchain() { # <platform>
  case "${1:-}" in
    linux-*)   printf 'container' ;;
    windows-*) printf 'runner' ;;
    *) echo "error: unknown platform '${1:-}'" >&2; return 2 ;;
  esac
}

BUILD_IMAGE_REPO="iree-runtime-dist-build"
# Build-image identity, keyed off the platform token above -- one token, so tag,
# Dockerfile, and artifact platform cannot drift. Defined ONLY for container
# platforms: asking a runner platform for a build image is a programming error,
# and returning an empty string would silently produce `docker build -f ''`.
_require_container_platform() { # <platform> <caller>
  if [ "$(platform_toolchain "$1")" != container ]; then
    echo "error: $2 called for non-container platform '$1'" >&2; return 2
  fi
}
build_image_tag()  { # <platform>
  _require_container_platform "$1" build_image_tag || return 2
  printf '%s:%s' "$BUILD_IMAGE_REPO" "$1"
}
build_dockerfile() { # <platform>, repo-relative
  _require_container_platform "$1" build_dockerfile || return 2
  printf 'docker/%s.Dockerfile' "$1"
}
platforms_json() { # JSON array, for GitHub Actions' fromJson() in a matrix
  python3 -c "import json,sys; print(json.dumps(sys.argv[1].split()))" "$PLATFORMS"
}

# Container-only subset of PLATFORMS. Anything that iterates platforms to
# build/resolve a Docker image (scripts/build-image.sh, warm-build-image.yml)
# must use this, not known_platforms/platforms_json -- a runner platform has
# no Dockerfile, and build_image_tag/build_dockerfile fail loudly for one.
# release.yml still needs the FULL list (platforms_json) since Windows IS a
# release platform even though it is not a build-image platform; do not
# collapse the two lists into one.
container_platforms() {
  for p in $(known_platforms); do
    if [ "$(platform_toolchain "$p")" = container ]; then
      printf '%s\n' "$p"
    fi
  done
}
containers_json() { # JSON array, container platforms only
  python3 -c "import json,sys; print(json.dumps(sys.argv[1].split()))" "$(container_platforms | tr '\n' ' ')"
}
