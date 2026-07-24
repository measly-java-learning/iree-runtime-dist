# Pinned to a specific tag rather than `latest` as that matches up with
# the attitude of the rest of the project
FROM quay.io/pypa/manylinux_2_28_aarch64:2026.06.04-1

# NEVRA values were verified by manual inspection of this container tag
RUN dnf install -y \
      clang-21.1.8-1.module_el8.10.0+4172+b6b13d75 \
      lld-21.1.8-1.module_el8.10.0+4172+b6b13d75 \
      ninja-build-1.8.2-1.el8 \
    && dnf clean all \
    && rm -rf /var/cache/dnf