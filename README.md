# StarLite Image Patcher

Prepares a FydeOS or OpenFyde disk image for the Star Labs StarLite. The image’s own release and kernel are read and kept. The result adds screen rotation, BlueZ, remembered brightness, lid and external-display handling, tablet mode, sleep, a verity re-seal, and the Wi-Fi and TPM fixes.

A newer release is recognized automatically. The build finishes when an accelerometer module for that kernel is already in this repository.

## Versions

| Product | Release | Kernel | Result |
|---|---|---|---|
| OpenFyde | 16503.20.22.5 (`amd64-openfyde_iris`) | `6.6.99-09011-gfdc62122de5f-dirty` | Rotation works. Trigger name `mxc4005-hr`. |
| FydeOS for PC | v23.0-SP1, 16700.56.23.51 (`amd64-fydeos_iris-io`) | `6.12.54-01180-gb4e10020ba49-dirty` | Rotation works. Trigger name `iioservice-0`. |

## Script

```bash
./scripts/build-fydeos-starlite.sh --lean INPUT.bin OUTPUT.bin
./scripts/build-fydeos-starlite.sh --identify INPUT.bin
```

`--identify` prints the product, release, and kernel and does not write an image. Host tools required: `guestfish`, `sgdisk`, and `python3`. Verity and kernel repack tools are included in this repository. The re-seal uses the public Chromium OS developer kernel key.

## Flatpak

Release 1.2.0 is attached to this repository’s GitHub release. It is the same patch, with a window for choosing the input and output images.

```bash
flatpak install -y flathub org.gnome.Platform//48
flatpak install --user StarLite-Image-Patcher-1.2.0.flatpak
flatpak run io.openfyde.StarLitePatcher
```

The app runs the script on the host. Clone this repository to `~/StarLite-Image-Patcher`, or set `STARLITE_PATCH_SCRIPT` to `scripts/build-fydeos-starlite.sh`.

To build the Flatpak from source, see `flatpak/README.md`.
