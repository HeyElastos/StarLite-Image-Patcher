"""Host script discovery and subprocess runner for the StarLite inject."""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
from collections.abc import Callable
from pathlib import Path

LOCAL_SHARE_SCRIPT = Path.home() / ".local/share/starlite-patcher/build-fydeos-starlite.sh"
CLONE_SCRIPT = Path.home() / "StarLite-Image-Patcher" / "scripts" / "build-fydeos-starlite.sh"
CLONE_WRAPPER = Path.home() / "StarLite-Image-Patcher" / "scripts" / "starlite-patcher-host.sh"

LogCallback = Callable[[str], None]
DoneCallback = Callable[[int, Path | None], None]


def running_in_flatpak() -> bool:
    return Path("/.flatpak-info").is_file() or bool(os.environ.get("FLATPAK_ID"))


def find_patch_script() -> Path | None:
    """Resolve build-fydeos-starlite.sh (or host wrapper) in priority order."""
    env = os.environ.get("STARLITE_PATCH_SCRIPT", "").strip()
    if env:
        p = Path(env).expanduser()
        if p.is_file():
            return p

    for candidate in (
        LOCAL_SHARE_SCRIPT,
        CLONE_SCRIPT,
        CLONE_WRAPPER,
    ):
        if candidate.is_file():
            return candidate

    # Bundled data (v2+): script next to package or under /app/share
    here = Path(__file__).resolve().parent
    for bundled in (
        here / "data" / "build-fydeos-starlite.sh",
        Path("/app/share/starlite-patcher/build-fydeos-starlite.sh"),
        here.parent.parent / "scripts" / "build-fydeos-starlite.sh",
        here.parent.parent / "scripts" / "starlite-patcher-host.sh",
    ):
        if bundled.is_file():
            return bundled

    return None


def default_output_for(input_path: Path) -> Path:
    """Same directory as input, with -StarLite-fixed.bin suffix."""
    name = input_path.name
    lower = name.lower()
    if lower.endswith(".bin.zip"):
        stem = name[: -len(".bin.zip")]
    elif lower.endswith(".zip"):
        stem = name[: -len(".zip")]
    elif lower.endswith(".bin"):
        stem = name[: -len(".bin")]
    else:
        stem = input_path.stem
    return input_path.with_name(f"{stem}-StarLite-fixed.bin")


def _host_exists(path: Path) -> bool:
    """Check path existence; when sandboxed, probe the host filesystem."""
    if path.exists():
        return True
    if not running_in_flatpak():
        return False
    if not shutil.which("flatpak-spawn"):
        return False
    try:
        r = subprocess.run(
            ["flatpak-spawn", "--host", "test", "-e", str(path)],
            check=False,
            capture_output=True,
            timeout=30,
        )
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def resolve_script_for_run() -> tuple[Path | None, str]:
    """Return (script_path, note). Prefers paths visible on the host."""
    script = find_patch_script()
    if script is not None:
        # Inside Flatpak, host tree paths may not be visible via Path.exists
        # if --filesystem=host is missing; still return absolute path for spawn.
        if running_in_flatpak() or script.is_file() or _host_exists(script):
            return script, f"Using: {script}"
    if running_in_flatpak() and _host_exists(CLONE_SCRIPT):
        return CLONE_SCRIPT, f"Using host: {CLONE_SCRIPT}"
    if running_in_flatpak() and _host_exists(CLONE_WRAPPER):
        return CLONE_WRAPPER, f"Using host wrapper: {CLONE_WRAPPER}"
    return None, (
        "Patch script not found. Set STARLITE_PATCH_SCRIPT, or clone this "
        "repository to ~/StarLite-Image-Patcher."
    )


def identify_command(script: Path, input_bin: Path) -> list[str]:
    """Read the image release and kernel without writing an output image."""
    in_abs = str(input_bin.resolve())
    script_abs = str(script) if script.is_absolute() else str(script.resolve())
    if running_in_flatpak():
        spawn = shutil.which("flatpak-spawn") or "flatpak-spawn"
        return [spawn, "--host", "bash", script_abs, "--identify", in_abs]
    return ["bash", script_abs, "--identify", in_abs]


def parse_identity(text: str) -> dict[str, str] | None:
    """Parse the IDENT|family|version|board|build|kver|module|known line."""
    for line in text.splitlines():
        if not line.startswith("IDENT|"):
            continue
        parts = line.split("|")
        if len(parts) < 8:
            continue
        return {
            "family": parts[1],
            "version": parts[2],
            "board": parts[3],
            "build": parts[4],
            "kver": parts[5],
            "module": parts[6],
            "known": parts[7],
        }
    return None


def format_identity(info: dict[str, str]) -> str:
    if info["module"] == "ready":
        module = "accelerometer module ready"
    else:
        have = info["known"] or "none"
        module = f"no accelerometer module for this kernel (have {have})"
    return (
        f"{info['family']} {info['version']} · {info['board']} · "
        f"{info['build']} · kernel {info['kver']} · {module}"
    )


def identify_image(script: Path, input_bin: Path) -> dict[str, str]:
    cmd = identify_command(script, input_bin)
    try:
        result = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=180,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(str(exc)) from exc
    text = f"{result.stdout or ''}\n{result.stderr or ''}"
    info = parse_identity(text)
    if info is None:
        detail = text.strip() or f"exit {result.returncode}"
        raise RuntimeError(detail)
    return info


def build_command(script: Path, input_bin: Path, output_bin: Path) -> list[str]:
    """Build argv: flatpak-spawn --host when sandboxed, else direct exec."""
    in_abs = str(input_bin.resolve())
    out_abs = str(output_bin.resolve()) if output_bin.is_absolute() else str(output_bin)
    # Prefer absolute script path for host spawn
    script_abs = str(script) if script.is_absolute() else str(script.resolve())

    # --lean keeps ARC, Crostini, Files, SELinux, and verity.
    # Do not pass --skip-mxc: that ships an image whose accelerometer cannot load.
    if running_in_flatpak():
        spawn = shutil.which("flatpak-spawn") or "flatpak-spawn"
        return [spawn, "--host", "bash", script_abs, "--lean", in_abs, out_abs]
    return ["bash", script_abs, "--lean", in_abs, out_abs]


def unzip_to_sibling(
    zip_path: Path,
    log: LogCallback,
) -> Path:
    """Unzip .bin.zip / .zip to a sibling .bin next to the archive."""
    import zipfile

    zip_path = zip_path.resolve()
    if not zip_path.is_file():
        raise FileNotFoundError(f"Zip not found: {zip_path}")

    log(f"Unzipping {zip_path.name} …")
    with zipfile.ZipFile(zip_path, "r") as zf:
        bins = [n for n in zf.namelist() if n.lower().endswith(".bin") and not n.endswith("/")]
        if not bins:
            raise RuntimeError("No .bin file inside the zip — unzip manually and try again.")
        # Prefer a top-level single .bin
        bins_sorted = sorted(bins, key=lambda n: (n.count("/"), len(n)))
        member = bins_sorted[0]
        base = Path(member).name
        dest = zip_path.parent / base
        if dest.exists():
            # Avoid clobbering: use stem from zip name
            stem = zip_path.name
            for suf in (".bin.zip", ".zip"):
                if stem.lower().endswith(suf):
                    stem = stem[: -len(suf)]
                    break
            dest = zip_path.parent / f"{stem}.bin"
        log(f"Extracting {member} → {dest}")
        with zf.open(member) as src, open(dest, "wb") as out:
            shutil.copyfileobj(src, out)
        size = dest.stat().st_size
        log(f"Unzip done ({size:,} bytes).")
        return dest


def format_size(num: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if num < 1024.0 or unit == "TiB":
            if unit == "B":
                return f"{num} {unit}"
            return f"{num:.2f} {unit}"
        num /= 1024.0
    return f"{num} B"


class PatchJob:
    """Run the host patcher asynchronously with line-buffered log output."""

    def __init__(self) -> None:
        self._proc: subprocess.Popen[str] | None = None
        self._thread: threading.Thread | None = None
        self._cancel = threading.Event()

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(
        self,
        input_path: Path,
        output_path: Path,
        on_log: LogCallback,
        on_done: DoneCallback,
    ) -> None:
        if self.running:
            raise RuntimeError("A patch job is already running")

        self._cancel.clear()
        self._thread = threading.Thread(
            target=self._run,
            args=(input_path, output_path, on_log, on_done),
            daemon=True,
            name="starlite-patch",
        )
        self._thread.start()

    def _run(
        self,
        input_path: Path,
        output_path: Path,
        on_log: LogCallback,
        on_done: DoneCallback,
    ) -> None:
        final_out: Path | None = None
        code = 1
        try:
            work_in = input_path
            lower = input_path.name.lower()
            if lower.endswith(".zip"):
                try:
                    work_in = unzip_to_sibling(input_path, on_log)
                except Exception as exc:  # noqa: BLE001 — surface to UI log
                    on_log(f"ERROR: {exc}")
                    on_done(1, None)
                    return

            script, note = resolve_script_for_run()
            on_log(note)
            if script is None:
                on_done(1, None)
                return

            output_path.parent.mkdir(parents=True, exist_ok=True)
            cmd = build_command(script, work_in, output_path)
            on_log(f"$ {' '.join(cmd)}")
            on_log("")

            env = os.environ.copy()
            env["PYTHONUNBUFFERED"] = "1"
            # Line-buffer bash stdout when possible
            self._proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=env,
            )
            assert self._proc.stdout is not None
            for line in self._proc.stdout:
                if self._cancel.is_set():
                    break
                on_log(line.rstrip("\n"))
            code = self._proc.wait()
            if code == 0 and output_path.exists():
                final_out = output_path
                on_log("")
                on_log(
                    f"SUCCESS: {final_out} ({format_size(final_out.stat().st_size)})"
                )
            elif code == 0:
                # Host wrote elsewhere or sandbox cannot see output — still success
                final_out = output_path
                on_log("")
                on_log(f"SUCCESS (exit 0). Expected output: {output_path}")
            else:
                on_log("")
                on_log(f"FAILED with exit code {code}")
        except Exception as exc:  # noqa: BLE001
            on_log(f"ERROR: {exc}")
            code = 1
        finally:
            self._proc = None
            on_done(code, final_out)
