# Jellyfin for Radxa Orion O6 (CIX Sky1 / CD8180) — VPU hardware transcoding

An arm64 Jellyfin image for the **Radxa Orion O6** (CIX Sky1 / CD8180 SoC) that
uses the on-chip **Linlon / MVX VPU** for hardware video **decode and encode**,
with a CPU-tuned software-encode fallback.

It combines:

1. **FFmpeg with the Sky1 V4L2 M2M patches** ([Sky1-Linux/ffmpeg-sky1](https://github.com/Sky1-Linux/ffmpeg-sky1)) — VPU decode/encode for H.264, HEVC, AV1 (decode), VP8/VP9, MPEG2/4, VC1.
2. **x264, x265 (8/10/12-bit) and libaom built from source, tuned for Armv9.2-A** (`-march=armv9.2-a -mtune=cortex-a720`) with SVE2 — the software HEVC/H.264/AV1 encoders used when the VPU isn't chosen.
3. **A patched Jellyfin 10.11.11** (server + web) that actually drives, controls, and reports the VPU. Stock Jellyfin only wires V4L2 M2M for H.264 encode; the patches extend it to the full VPU pipeline and surface hardware usage in the UI.

> The VPU only works on a real Sky1 host running the Sky1 kernel + firmware
> (`/dev/video*`, `/dev/dma_heap`). The image builds anywhere, but hardware
> transcoding requires the O6.

---

## What was changed

### FFmpeg (`Dockerfile.ffmpeg`, `build-encoders.sh`)

- Builds FFmpeg 8.0 from the `Sky1-Linux/ffmpeg-sky1` `sky1` branch (V4L2 M2M VPU decode/encode + auto-hwaccel).
- Rebuilds **x264, x265 (8/10/12-bit multilib) and libaom from source** with `-march=armv9.2-a -mtune=cortex-a720`, statically linked into FFmpeg, so the software encoders use SVE2/i8mm on the A720/A520 cores.
- Stamps a numeric FFmpeg version (`8.0`). The `sky1` branch is a tagless checkout, so FFmpeg otherwise reports a git hash that Jellyfin can't parse — which makes Jellyfin reject the encoder and fail to start.
- Overlays the result onto the official `jellyfin/jellyfin` image (Debian trixie / GCC 14) so the compiled FFmpeg's ABI matches the runtime.

### Jellyfin server (`patches/jellyfin-server.patch`, applied to v10.11.11)

- **`EncoderValidator.cs`** — register the V4L2 M2M **encoder** `hevc_v4l2m2m` and the V4L2 M2M **decoders** (`h264/hevc/mpeg1/mpeg2/mpeg4/vc1/vp8/vp9/av1 _v4l2m2m`). Jellyfin's `SupportsEncoder`/`SupportsDecoder` only trust whitelisted codecs, so without this the HEVC VPU encoder and all VPU decoders are silently ignored.
- **`EncodingHelper.cs`**
  - Generalize the three `h264_v4l2m2m`-only code paths (skip `-profile:v`, VPU 64px width alignment) to **any** `_v4l2m2m` encoder, so HEVC gets correct handling.
  - Gate `hevc_v4l2m2m` selection behind a new opt-in option (below) — falls back to software x265 when off.
  - `GetV4l2VidDecoder` + decoder-switch wiring: a **ticked** decode codec emits an explicit ` -c:v <codec>_v4l2m2m`, and the V4L2 M2M decoder is treated as software-frames in the filter chain (system-memory output → `yuv420p` software filters, matching the working pipeline).
  - `IsHardwareVideoEncoder` / `IsHardwareVideoDecoder`: report whether the **actual** chosen encoder/decoder is hardware (the decoder check also accounts for the ffmpeg-sky1 auto-hwaccel).
- **`EncodingOptions.cs`** — new `EnableV4l2m2mHevcEncoder` option (default off).
- **`TranscodingInfo.cs` / `TranscodeManager.cs`** — new `IsHardwareDecoding` / `IsHardwareEncoding` fields, populated from the real pipeline during transcoding.

### Jellyfin web (`patches/jellyfin-web.patch`, applied to v10.11.11)

- **`transcoding.tsx`** — a **"Enable HEVC hardware encoding (VPU / V4L2M2M)"** checkbox on the Transcoding page, shown only when Hardware acceleration = Video4Linux2 (V4L2M2M).
- **`codecs.ts`** — the "Enable hardware decoding for" list under V4L2M2M now shows every VPU-decodable codec (H264/HEVC/MPEG1/MPEG2/MPEG4/VC1/VP8/VP9/AV1) plus the HEVC/VP9 10-bit toggles.
- **`playerstats.js`** — the playback stats overlay now shows **Hardware decoding: Yes/No** and **Hardware encoding: Yes/No**, computed server-side from the real decoder/encoder (upstream had this disabled because it only reflected config).

---

## Repository layout

```
Dockerfile.ffmpeg          # Stage 1: Sky1 FFmpeg + armv9.2 encoders → base image
build-encoders.sh          #          x264/x265/libaom source build
Dockerfile.jellyfin        # Stage 2: patched Jellyfin server+web onto the base
patches/
  jellyfin-server.patch    # 5 files, applied to jellyfin v10.11.11
  jellyfin-web.patch        # 3 files, applied to jellyfin-web v10.11.11
build.sh                   # clone + patch + build both stages
docker-compose.yml         # deploy on the O6 with VPU passthrough
```

## Build

Needs Docker with buildx and QEMU arm64:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
./build.sh                 # → jellyfin-orion-o6:latest
```

Stage 1 (FFmpeg) compiles under arm64 emulation (~25 min). The Jellyfin server
(.NET) and web (webpack) cross-compile natively on the build host. Then push:

```bash
docker tag jellyfin-orion-o6:latest <your-registry>/jellyfin-orion-o6:latest
docker push <your-registry>/jellyfin-orion-o6:latest
```

## Deploy (on the Orion O6)

Find the VPU nodes: `ls -l /dev/video*` (decode is typically `/dev/video0`,
encode `/dev/video1`) and `ls -l /dev/dma_heap`. Edit `docker-compose.yml` for
your media path and device nodes, then:

```bash
docker compose up -d
```

## Usage

**Dashboard → Playback → Transcoding**, Hardware acceleration = **Video4Linux2 (V4L2M2M)**:

- **Enable hardware decoding for** — tick the codecs you want decoded on the VPU (HEVC, AV1, …).
- **Enable hardware encoding** — H.264 VPU encode.
- **Enable HEVC hardware encoding (VPU / V4L2M2M)** — HEVC VPU encode (opt-in; otherwise software x265). Also requires "Allow encoding in HEVC format".
- Do **not** enable AV1 encoding — the VPU has no AV1 encoder (software libaom only).

Open the playback **stats overlay** during a transcode to see **Hardware
decoding** and **Hardware encoding** status.

## Verify

Startup log (`docker logs`) should list the VPU codecs:

```
Available decoders: [..., "av1_v4l2m2m", "hevc_v4l2m2m", "h264_v4l2m2m", ...]
Available encoders: [..., "h264_v4l2m2m", "hevc_v4l2m2m", ...]
```

In a transcode's FFmpeg log, the `Stream mapping` shows e.g.
`av1 (av1_v4l2m2m) -> hevc (hevc_v4l2m2m)` (both on the VPU).

## Known limitations

- The ffmpeg-sky1 **auto-hwaccel always decodes on the VPU** when a matching
  decoder exists, so *un*-ticking a decode codec does **not** currently force
  software decode — it only stops Jellyfin from selecting the decoder
  explicitly. Making "disable HW decode" fully honored (for A/B measurement)
  needs an FFmpeg-side change and is not yet included.
- V4L2 M2M encoder rate control is basic (no B-frames / psy-opt); at equal
  bitrate the SVE2-tuned x265 may look better. The VPU wins on throughput
  (~7× real-time vs ~2.5×) and CPU offload.
- HEVC output only triggers when the client/device profile requests HEVC.

## Upstream

- Jellyfin: <https://github.com/jellyfin/jellyfin> / <https://github.com/jellyfin/jellyfin-web> (GPLv3)
- FFmpeg Sky1 patches: <https://github.com/Sky1-Linux/ffmpeg-sky1>
- Radxa Orion O6 / CIX Sky1: <https://github.com/Sky1-Linux>

Patches are against Jellyfin `v10.11.11`; re-apply against the surrounding code
on version bumps.
