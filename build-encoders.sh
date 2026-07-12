#!/usr/bin/env bash
###############################################################################
# Build x264, x265 (8/10/12-bit multilib), and libaom from source, tuned for
# the CIX Sky1 (CD8180) — Armv9.2-A, Cortex-A720/A520, SVE2.
#
# All three are built as STATIC, PIC libraries into $PREFIX so FFmpeg can link
# them statically (the resulting ffmpeg carries the tuned encoders; the final
# image needs no distro x264/x265/aom).
###############################################################################
set -euxo pipefail

PREFIX="${PREFIX:-/opt/sky1-deps}"
MARCH="${MARCH:-armv9.2-a}"
MTUNE="${MTUNE:-cortex-a720}"
ARCH_FLAGS="-march=${MARCH} -mtune=${MTUNE} -O3 -fPIC"
JOBS="$(nproc)"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
mkdir -p "${PREFIX}" /src
cd /src

# --- x264 (VideoLAN, autotools) -------------------------------------------
git clone --depth 1 https://code.videolan.org/videolan/x264.git
cd x264
./configure \
    --prefix="${PREFIX}" \
    --enable-static \
    --enable-pic \
    --disable-cli \
    --extra-cflags="${ARCH_FLAGS}" \
    --extra-asflags="${ARCH_FLAGS}"
make -j"${JOBS}"
make install
cd /src

# --- x265 (MulticoreWare, cmake) — 8/10/12-bit multilib -------------------
# 10/12-bit support matters for HDR (Main10) HEVC transcodes.
git clone --depth 1 --branch 4.1 https://bitbucket.org/multicoreware/x265_git.git x265
cd x265
COMMON_X265=(
    -DCMAKE_INSTALL_PREFIX="${PREFIX}"
    -DENABLE_SHARED=OFF
    -DENABLE_CLI=OFF
    -DENABLE_PIC=ON
    -DENABLE_ASSEMBLY=ON
    -DCMAKE_C_FLAGS="${ARCH_FLAGS}"
    -DCMAKE_CXX_FLAGS="${ARCH_FLAGS}"
)
mkdir -p build/8bit build/10bit build/12bit
# 12-bit
cmake -S source -B build/12bit "${COMMON_X265[@]}" -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF
make -C build/12bit -j"${JOBS}"
# 10-bit
cmake -S source -B build/10bit "${COMMON_X265[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
make -C build/10bit -j"${JOBS}"
# 8-bit (main), linking in the 10/12-bit archives
cp build/10bit/libx265.a build/8bit/libx265_main10.a
cp build/12bit/libx265.a build/8bit/libx265_main12.a
cmake -S source -B build/8bit "${COMMON_X265[@]}" \
    -DEXTRA_LIB="x265_main10.a;x265_main12.a" \
    -DEXTRA_LINK_FLAGS=-L. \
    -DLINKED_10BIT=ON \
    -DLINKED_12BIT=ON
make -C build/8bit -j"${JOBS}"
make -C build/8bit install   # installs headers, x265.pc, and the 8-bit-only lib
# Merge the three archives into one static lib that ffmpeg will link.
cd build/8bit
mv libx265.a libx265_main.a
ar -M <<'EOF'
CREATE libx265.a
ADDLIB libx265_main.a
ADDLIB libx265_main10.a
ADDLIB libx265_main12.a
SAVE
END
EOF
cp -f libx265.a "${PREFIX}/lib/libx265.a"
cd /src

# --- libaom (AV1, cmake) ---------------------------------------------------
git clone --depth 1 --branch v3.11.0 https://aomedia.googlesource.com/aom
cmake -S aom -B aom_build \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DAOM_TARGET_CPU=arm64 \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DCONFIG_PIC=1 \
    -DENABLE_TESTS=OFF \
    -DENABLE_DOCS=OFF \
    -DENABLE_EXAMPLES=OFF \
    -DENABLE_TOOLS=OFF \
    -DCMAKE_C_FLAGS="${ARCH_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${ARCH_FLAGS}"
make -C aom_build -j"${JOBS}"
make -C aom_build install

echo "== encoders built into ${PREFIX} (march=${MARCH}, mtune=${MTUNE}) =="
ls -l "${PREFIX}/lib"/libx264.a "${PREFIX}/lib"/libx265.a "${PREFIX}/lib"/libaom.a
