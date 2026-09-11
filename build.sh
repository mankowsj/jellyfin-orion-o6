#!/usr/bin/env bash
#
# Build the arm64 Jellyfin image for the Radxa Orion O6 (CIX Sky1 / CD8180):
#   1. FFmpeg base image  — Sky1 VPU (V4L2 M2M) ffmpeg with armv9.2-tuned
#      x264/x265/libaom built from source, on top of jellyfin/jellyfin.
#   2. Standalone ffmpeg   — the same binaries extracted to dist/ffmpeg-sky1/,
#      for dropping into other V4L2M2M consumers (e.g. Immich's jellyfin-ffmpeg).
#   3. Patched Jellyfin    — server + web patches applied to v10.11.11.
#
# The server (.NET) and web (webpack) cross-compile natively on the build host;
# only FFmpeg is compiled under arm64 emulation. Requires Docker with buildx and
# QEMU arm64 (docker run --privileged --rm tonistiigi/binfmt --install arm64).
#
# Usage: ./build.sh [output-tag]        (default: jellyfin-orion-o6:latest)

set -euo pipefail

TAG="${1:-jellyfin-orion-o6:latest}"
BASE_TAG="jellyfin-orion-o6-base:latest"
JELLYFIN_TAG="v10.11.11"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$REPO_DIR/dist/ffmpeg-sky1"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 1/4  Building FFmpeg base image ($BASE_TAG) — this is the slow one (emulated)"
docker buildx build --platform linux/arm64 \
  -f "$REPO_DIR/Dockerfile.ffmpeg" \
  -t "$BASE_TAG" --load "$REPO_DIR"

echo "==> 2/4  Extracting standalone ffmpeg/ffprobe to $DIST_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$(dirname "$DIST_DIR")"
CID="$(docker create "$BASE_TAG")"
docker cp "$CID:/opt/ffmpeg-sky1" "$DIST_DIR"
docker rm "$CID" >/dev/null
# Best-effort re-check (the build itself already asserts this inside emulated
# buildkit); running the arm64 binary directly here only works if binfmt is
# registered for plain host execution too, so don't fail the script over it.
"$DIST_DIR/bin/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q vp9_v4l2m2m \
  && echo "    -> vp9_v4l2m2m confirmed present" \
  || echo "    -> (couldn't re-exec the arm64 binary here to confirm vp9_v4l2m2m; the build already did)"
echo "    -> $DIST_DIR/bin/{ffmpeg,ffprobe}  (drop-in for /usr/lib/jellyfin-ffmpeg/ in Immich etc.)"

echo "==> 3/4  Cloning Jellyfin $JELLYFIN_TAG and applying patches"
git clone --depth 1 --branch "$JELLYFIN_TAG" https://github.com/jellyfin/jellyfin.git "$WORK/jellyfin"
git clone --depth 1 --branch "$JELLYFIN_TAG" https://github.com/jellyfin/jellyfin-web.git "$WORK/jellyfin-web"
git -C "$WORK/jellyfin"     apply "$REPO_DIR/patches/jellyfin-server.patch"
git -C "$WORK/jellyfin-web" apply "$REPO_DIR/patches/jellyfin-web.patch"

echo "==> 4/4  Building patched Jellyfin image ($TAG)"
docker buildx build --platform linux/arm64 \
  -f "$REPO_DIR/Dockerfile.jellyfin" \
  --build-arg "BASE_IMAGE=$BASE_TAG" \
  --build-context "websrc=$WORK/jellyfin-web" \
  -t "$TAG" --load "$WORK/jellyfin"

echo "==> Done: $TAG"
echo "    Push with:  docker push $TAG   (after docker tag if needed)"
echo "    Standalone ffmpeg-sky1 (arm64) at: $DIST_DIR/bin/"
