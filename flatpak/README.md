# StarLite Image Patcher

Flatpak front end for the StarLite image script. App ID: `io.openfyde.StarLitePatcher`. FydeOS and OpenFyde use different accelerometer trigger names. The script selects the module that matches the image.

The sandbox cannot run the image tools, so the app launches the host script with `flatpak-spawn --host`.

## Find the script

1. `STARLITE_PATCH_SCRIPT`
2. `~/.local/share/starlite-patcher/build-fydeos-starlite.sh`
3. `~/StarLite-Image-Patcher/scripts/build-fydeos-starlite.sh`
4. `~/StarLite-Image-Patcher/scripts/starlite-patcher-host.sh`

## Build

```bash
flatpak install -y flathub org.gnome.Platform//48 org.gnome.Sdk//48
flatpak-builder --user --install --force-clean build-dir io.openfyde.StarLitePatcher.json
flatpak run io.openfyde.StarLitePatcher
```
