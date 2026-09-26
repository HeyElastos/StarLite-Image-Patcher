#!/usr/bin/env python3
"""StarLite Image Patcher — Adw/GTK4 UI."""

from __future__ import annotations

import os
import sys
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from .patcher import (  # noqa: E402
    PatchJob,
    default_output_for,
    find_patch_script,
    format_identity,
    format_size,
    identify_image,
    resolve_script_for_run,
    running_in_flatpak,
)

APP_ID = "io.openfyde.StarLitePatcher"


class StarLitePatcherWindow(Adw.ApplicationWindow):
    def __init__(self, app: Adw.Application) -> None:
        super().__init__(application=app, title="StarLite Image Patcher")
        self.set_default_size(720, 560)
        self._job = PatchJob()
        self._input_path: Path | None = None
        self._output_path: Path | None = None
        self._updating_output = False

        toast_overlay = Adw.ToastOverlay()
        self.set_content(toast_overlay)
        self._toasts = toast_overlay

        toolbar = Adw.ToolbarView()
        toast_overlay.set_child(toolbar)

        header = Adw.HeaderBar()
        header.set_title_widget(Adw.WindowTitle(
            title="StarLite Image Patcher",
            subtitle="FydeOS and OpenFyde, matched to each image kernel",
        ))
        toolbar.add_top_bar(header)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        root.set_margin_top(12)
        root.set_margin_bottom(12)
        root.set_margin_start(16)
        root.set_margin_end(16)
        toolbar.set_content(root)

        # Status / script discovery
        self._script_label = Gtk.Label(xalign=0.0)
        self._script_label.add_css_class("dim-label")
        self._script_label.set_wrap(True)
        self._refresh_script_label()
        root.append(self._script_label)

        prefs = Adw.PreferencesGroup(title="Images")
        root.append(prefs)

        # Input row
        self._input_row = Adw.ActionRow(
            title="Input image",
            subtitle="FydeOS or OpenFyde .bin or .bin.zip",
        )
        browse_in = Gtk.Button(label="Browse")
        browse_in.add_css_class("flat")
        browse_in.connect("clicked", self._on_browse_input)
        self._input_row.add_suffix(browse_in)
        self._input_row.set_activatable_widget(browse_in)
        prefs.add(self._input_row)

        # Output row
        self._output_row = Adw.ActionRow(
            title="Output image",
            subtitle="Defaults to «name»-StarLite-fixed.bin beside input",
        )
        browse_out = Gtk.Button(label="Browse")
        browse_out.add_css_class("flat")
        browse_out.connect("clicked", self._on_browse_output)
        self._output_row.add_suffix(browse_out)
        self._output_row.set_activatable_widget(browse_out)
        prefs.add(self._output_row)

        # Actions
        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        actions.set_halign(Gtk.Align.END)
        root.append(actions)

        self._spinner = Gtk.Spinner()
        actions.append(self._spinner)

        self._status = Gtk.Label(label="Ready", xalign=0.0, hexpand=True)
        self._status.add_css_class("dim-label")
        actions.append(self._status)

        self._patch_btn = Gtk.Button(label="Patch")
        self._patch_btn.add_css_class("suggested-action")
        self._patch_btn.add_css_class("pill")
        self._patch_btn.connect("clicked", self._on_patch)
        actions.append(self._patch_btn)

        # Log view
        log_frame = Gtk.Frame(label="Log")
        log_frame.set_vexpand(True)
        root.append(log_frame)

        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scrolled.set_min_content_height(240)
        scrolled.set_vexpand(True)
        log_frame.set_child(scrolled)

        self._log = Gtk.TextView(
            editable=False,
            cursor_visible=False,
            monospace=True,
            wrap_mode=Gtk.WrapMode.WORD_CHAR,
        )
        self._log.add_css_class("log-view")
        scrolled.set_child(self._log)
        self._log_buf = self._log.get_buffer()

        self._append_log(
            "StarLite Image Patcher\n"
            "Pick a FydeOS or OpenFyde .bin. The release and kernel are read from the image.\n"
            "The Flatpak sandbox invokes the host inject via flatpak-spawn --host.\n"
        )

    def _refresh_script_label(self) -> None:
        script = find_patch_script()
        mode = "Flatpak → host" if running_in_flatpak() else "direct (unpackaged)"
        if script:
            self._script_label.set_text(f"Patcher ({mode}): {script}")
        else:
            _, note = resolve_script_for_run()
            self._script_label.set_text(f"Patcher ({mode}): not found — {note}")

    def _append_log(self, text: str) -> None:
        end = self._log_buf.get_end_iter()
        if text and not text.endswith("\n"):
            text = text + "\n"
        self._log_buf.insert(end, text)
        # Auto-scroll
        mark = self._log_buf.create_mark(None, self._log_buf.get_end_iter(), False)
        self._log.scroll_to_mark(mark, 0.0, False, 0.0, 1.0)

    def _set_busy(self, busy: bool) -> None:
        self._patch_btn.set_sensitive(not busy)
        if busy:
            self._spinner.start()
            self._status.set_text("Patching…")
        else:
            self._spinner.stop()

    def _on_browse_input(self, _btn: Gtk.Button) -> None:
        dialog = Gtk.FileDialog(title="Select stock FydeOS / openFyde image")
        filters = Gio.ListStore.new(Gtk.FileFilter)
        f_bin = Gtk.FileFilter(name="FydeOS images (*.bin, *.bin.zip)")
        f_bin.add_pattern("*.bin")
        f_bin.add_pattern("*.BIN")
        f_bin.add_pattern("*.bin.zip")
        f_bin.add_pattern("*.zip")
        filters.append(f_bin)
        f_all = Gtk.FileFilter(name="All files")
        f_all.add_pattern("*")
        filters.append(f_all)
        dialog.set_filters(filters)
        dialog.set_default_filter(f_bin)
        dialog.open(self, None, self._on_input_chosen)

    def _on_input_chosen(self, dialog: Gtk.FileDialog, result: Gio.AsyncResult) -> None:
        try:
            file = dialog.open_finish(result)
        except GLib.Error:
            return
        if file is None:
            return
        path = Path(file.get_path())
        self._input_path = path
        self._input_row.set_subtitle(f"{path}\nReading release and kernel…")
        # Auto-fill output unless user already set a custom one for this input
        self._updating_output = True
        out = default_output_for(path)
        self._output_path = out
        self._output_row.set_subtitle(str(out))
        self._updating_output = False
        self._probe_input(path)

    def _probe_input(self, path: Path) -> None:
        if path.name.lower().endswith(".zip"):
            self._input_row.set_subtitle(f"{path}\nZip — release and kernel are read after unzip")
            return

        def work() -> None:
            script, note = resolve_script_for_run()
            if script is None:
                text = note
            else:
                try:
                    info = identify_image(script, path)
                    text = format_identity(info)
                except Exception as exc:  # noqa: BLE001 — show the probe failure in the row
                    text = f"Could not read this image: {exc}"
            GLib.idle_add(self._show_identity, path, text)

        threading.Thread(target=work, daemon=True, name="starlite-identify").start()

    def _show_identity(self, path: Path, text: str) -> bool:
        if self._input_path == path:
            self._input_row.set_subtitle(f"{path}\n{text}")
            self._append_log(text)
        return False

    def _on_browse_output(self, _btn: Gtk.Button) -> None:
        dialog = Gtk.FileDialog(title="Save StarLite-fixed image as")
        dialog.set_initial_name(
            self._output_path.name if self._output_path else "StarLite-fixed.bin"
        )
        if self._output_path:
            parent = Gio.File.new_for_path(str(self._output_path.parent))
            dialog.set_initial_folder(parent)
        dialog.save(self, None, self._on_output_chosen)

    def _on_output_chosen(self, dialog: Gtk.FileDialog, result: Gio.AsyncResult) -> None:
        try:
            file = dialog.save_finish(result)
        except GLib.Error:
            return
        if file is None:
            return
        path = Path(file.get_path())
        if not path.name.lower().endswith(".bin"):
            path = path.with_name(path.name + ".bin")
        self._output_path = path
        self._output_row.set_subtitle(str(path))

    def _on_patch(self, _btn: Gtk.Button) -> None:
        if self._job.running:
            return
        if not self._input_path:
            self._toast("Choose an input image first.")
            return
        if not self._output_path:
            self._output_path = default_output_for(self._input_path)
            self._output_row.set_subtitle(str(self._output_path))

        if not self._input_path.is_file():
            self._toast(f"Input not found:\n{self._input_path}")
            return

        self._refresh_script_label()
        self._append_log("")
        self._append_log(f"=== Patch started ===")
        self._append_log(f"Input:  {self._input_path}")
        self._append_log(f"Output: {self._output_path}")
        self._set_busy(True)

        def on_log(line: str) -> None:
            GLib.idle_add(self._append_log, line)

        def on_done(code: int, out: Path | None) -> None:
            GLib.idle_add(self._patch_finished, code, out)

        try:
            self._job.start(self._input_path, self._output_path, on_log, on_done)
        except Exception as exc:  # noqa: BLE001
            self._set_busy(False)
            self._append_log(f"ERROR: {exc}")
            self._toast(str(exc))

    def _patch_finished(self, code: int, out: Path | None) -> bool:
        self._set_busy(False)
        if code == 0:
            size_note = ""
            if out is not None and out.exists():
                size_note = f" ({format_size(out.stat().st_size)})"
                self._status.set_text(f"Done: {out.name}{size_note}")
                self._toast(f"Patched image ready:\n{out}{size_note}")
            else:
                self._status.set_text("Done (exit 0)")
                self._toast("Patch finished successfully.")
        else:
            self._status.set_text(f"Failed (exit {code})")
            self._toast("Patch failed — see log.")
        return GLib.SOURCE_REMOVE

    def _toast(self, message: str) -> None:
        self._toasts.add_toast(Adw.Toast(title=message, timeout=5))


class StarLitePatcherApp(Adw.Application):
    def __init__(self) -> None:
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.connect("activate", self._on_activate)

    def _on_activate(self, app: Adw.Application) -> None:
        win = self.props.active_window
        if not win:
            win = StarLitePatcherWindow(app)
        win.present()


def main(argv: list[str] | None = None) -> int:
    # Allow running as python3 -m starlite_patcher from the flatpak dir
    if argv is None:
        argv = sys.argv
    # Ensure package dir is importable when launched via /app/bin wrapper
    pkg_root = Path(__file__).resolve().parent.parent
    if str(pkg_root) not in sys.path:
        sys.path.insert(0, str(pkg_root))
    Adw.init()
    app = StarLitePatcherApp()
    return app.run(argv)


if __name__ == "__main__":
    raise SystemExit(main())
