# syntax=docker.io/docker/dockerfile:1.25.0

ARG BASE_IMAGE=docker.io/rockylinux/rockylinux:10.2.20260525.0

FROM --platform=${BUILDPLATFORM} ${BASE_IMAGE} AS base

ARG GITHUB_URL=https://github.com
# ARG GITHUB_URL=https://gh-proxy.org/https://github.com
# ARG GITHUB_URL=https://nexus-mirror.alpha-quant.tech/repository/github

# oras
# https://github.com/oras-project/oras/releases
ARG INST_ORAS_V=v1.4.0

ARG VENDOR_ARCHES="amd64 arm64"

ENV \
    GITHUB_URL=${GITHUB_URL} \
    INST_ORAS_V=${INST_ORAS_V} \
    VENDOR_ARCHES=${VENDOR_ARCHES}

# ---------------------------------------------------------------------------
# binaries
#    /cpaas/vendor/oras/<arch>/{oras,LICENSE}
#    /cpaas/vendor/oras/<arch>/{oras,LICENSE}.sha256sum
#    /cpaas/vendor/oras/<arch>/oras_<ver>_linux_<arch>.tar.gz.sha256
#
# ---------------------------------------------------------------------------
FROM --platform=${BUILDPLATFORM} base AS binaries

RUN --mount=type=cache,target=/tmp,id=build-tmp,sharing=locked \
    set -eu \
    && ver="${INST_ORAS_V#v}" \
    && base_url="${GITHUB_URL}/oras-project/oras/releases/download/${INST_ORAS_V}" \
    && sums="/tmp/oras_${ver}_checksums.txt" \
    && curl --fail -sL -m 60 --retry 3 --retry-delay 5 \
    "${base_url}/oras_${ver}_checksums.txt" -o "${sums}" \
    && for arch in ${VENDOR_ARCHES}; do \
    tarball="oras_${ver}_linux_${arch}.tar.gz" ; \
    dst="/cpaas/vendor/oras/${arch}" ; \
    curl --fail -sL -m 300 --retry 3 --retry-delay 5 \
    "${base_url}/${tarball}" -o "/tmp/${tarball}" ; \
    want_line="$(grep -E "^[0-9a-f]{64}  ${tarball}\$" "${sums}")" \
    || { echo "no upstream checksum for ${tarball} in oras_${ver}_checksums.txt" >&2; exit 1; } ; \
    ( cd /tmp && echo "${want_line}" | sha256sum --check --strict - ) ; \
    mkdir -p "${dst}" ; \
    tar zxf "/tmp/${tarball}" -C "${dst}" oras LICENSE ; \
    chmod +x "${dst}/oras" ; \
    ( cd "${dst}" && for f in * ; do sha256sum "${f}" > "${f}.sha256sum" ; done ) ; \
    echo "${want_line}" > "${dst}/${tarball}.sha256" ; \
    done

RUN set -eu \
    && for arch in ${VENDOR_ARCHES}; do \
    dst="/cpaas/vendor/oras/${arch}" ; \
    test -x "${dst}/oras" \
    || { echo "missing binary: ${arch}/oras" >&2; exit 1; } ; \
    test -s "${dst}/LICENSE" \
    || { echo "missing license: ${arch}/LICENSE" >&2; exit 1; } ; \
    magic="$(od -An -tx1 -N4 "${dst}/oras" | tr -d ' \n')" ; \
    test "${magic}" = "7f454c46" \
    || { echo "not an ELF binary: ${arch}/oras (magic=${magic})" >&2; exit 1; } ; \
    case "${arch}" in \
    amd64) want="3e00" ;; \
    arm64) want="b700" ;; \
    *) echo "unsupported arch: ${arch} (only amd64 / arm64)" >&2; exit 1 ;; \
    esac ; \
    machine="$(od -An -tx1 -j18 -N2 "${dst}/oras" | tr -d ' \n')" ; \
    test "${machine}" = "${want}" \
    || { echo "ELF arch mismatch: ${arch}/oras (e_machine=${machine}, want=${want})" >&2; exit 1; } ; \
    for f in oras LICENSE; do \
    test -s "${dst}/${f}.sha256sum" \
    || { echo "missing checksum: ${arch}/${f}.sha256sum" >&2; exit 1; } ; \
    done ; \
    ( cd "${dst}" && sha256sum --check --strict ./*.sha256sum ) ; \
    done

# ---------------------------------------------------------------------------
# target
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}

ARG TARGETARCH

# oras
# https://github.com/oras-project/oras/releases
ARG INST_ORAS_V=v1.4.0

ENV INST_ORAS_V=${INST_ORAS_V}

COPY --from=binaries /cpaas/vendor/oras/${TARGETARCH}/ /cpaas/vendor/oras/

LABEL \
    org.opencontainers.image.title="kluster-vendor-oras" \
    org.opencontainers.image.description="Upstream oras binaries repackaged as OCI artifacts" \
    org.opencontainers.image.version="${INST_ORAS_V}" \
    org.opencontainers.image.source="https://github.com/cpaas-dev/kluster-vendor-oras" \
    org.opencontainers.image.vendor="Kluster" \
    org.opencontainers.image.licenses="Apache-2.0"
