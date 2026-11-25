#!/usr/bin/env python3
"""Install a verified Manping app, keeping a rollback backup when replacing an existing app."""
import argparse
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from app_identity import APP_NAME, BUNDLE_ID, EXECUTABLE_NAME

ROOT = pathlib.Path(__file__).resolve().parents[1]
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def verify_app(app: pathlib.Path) -> None:
    if not app.is_dir() or app.suffix != ".app":
        raise RuntimeError(f"Not an app bundle: {app}")
    info_path = app / "Contents/Info.plist"
    executable = app / "Contents/MacOS" / EXECUTABLE_NAME
    if not info_path.is_file() or not executable.is_file():
        raise RuntimeError(f"Incomplete app bundle: {app}")
    if not os.access(executable, os.X_OK):
        raise RuntimeError(f"App executable is not executable: {executable}")
    with info_path.open("rb") as handle:
        identifier = plistlib.load(handle).get("CFBundleIdentifier")
    if identifier != BUNDLE_ID:
        raise RuntimeError(f"Unexpected bundle identifier {identifier!r}; expected {BUNDLE_ID!r}")
    subprocess.check_call(["codesign", "--verify", "--deep", "--strict", str(app)])


def is_running(app: pathlib.Path) -> bool:
    pattern = re.escape(str(app / "Contents/MacOS"))
    result = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    raise RuntimeError(result.stderr.strip() or "Could not check whether the app is running")


def install(source: pathlib.Path, destination: pathlib.Path, replace: bool, dry_run: bool, skip_register: bool) -> None:
    source = source.resolve()
    destination = destination.expanduser().absolute()
    verify_app(source)
    if source == destination:
        raise RuntimeError("Source and destination are the same app")
    if destination.suffix != ".app":
        raise RuntimeError("Destination must end in .app")
    if not destination.parent.is_dir():
        raise RuntimeError(f"Destination directory does not exist: {destination.parent}")
    if destination.exists() and not replace:
        raise RuntimeError("Destination exists; pass --replace to keep a backup and replace it")
    if is_running(destination):
        raise RuntimeError(f"Quit {destination.name} before installing")
    if dry_run:
        print(f"Verified {source}")
        print(f"Would install to {destination}")
        return

    staging_root = pathlib.Path(tempfile.mkdtemp(prefix=f".{destination.stem}.install-", dir=destination.parent))
    staged = staging_root / destination.name
    backup = None
    try:
        shutil.copytree(source, staged, symlinks=True)
        verify_app(staged)
        if destination.exists() or destination.is_symlink():
            stamp = time.strftime("%Y%m%d-%H%M%S")
            backup = destination.parent / f".{destination.stem}.backup-{stamp}-{uuid.uuid4().hex[:8]}"
            destination.rename(backup)
        try:
            staged.rename(destination)
        except BaseException:
            if backup is not None and backup.exists() and not destination.exists():
                backup.rename(destination)
                backup = None
            raise
        if not skip_register:
            try:
                subprocess.check_call([LSREGISTER, "-f", str(destination)])
            except (OSError, subprocess.CalledProcessError) as error:
                print(f"Installed, but LaunchServices registration failed: {error}", file=sys.stderr)
        print(f"Installed {destination}")
        if backup is not None:
            print(f"Backup {backup}")
    finally:
        shutil.rmtree(staging_root, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=pathlib.Path, default=ROOT / "dist/release" / APP_NAME)
    parser.add_argument("--destination", type=pathlib.Path, default=pathlib.Path("/Applications") / APP_NAME)
    parser.add_argument("--replace", action="store_true", help="Replace an existing app and retain a backup")
    parser.add_argument("--dry-run", action="store_true", help="Verify without changing the destination")
    parser.add_argument("--skip-register", action="store_true", help="Do not update LaunchServices")
    args = parser.parse_args()
    try:
        install(args.source, args.destination, args.replace, args.dry_run, args.skip_register)
    except (OSError, RuntimeError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"Install failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
