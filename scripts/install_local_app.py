#!/usr/bin/env python3
"""Install a verified Manping app, keeping a rollback backup when replacing an existing app."""
import argparse
import os
import pathlib
import plistlib
import re
import shutil
import signal
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


def running_pids(app: pathlib.Path) -> list[int]:
    pattern = re.escape(str(app / "Contents/MacOS"))
    result = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
    if result.returncode == 0:
        return [int(value) for value in result.stdout.split()]
    if result.returncode == 1:
        return []
    raise RuntimeError(result.stderr.strip() or "Could not check whether the app is running")


def quit_running(app: pathlib.Path) -> None:
    pids = running_pids(app)
    if not pids:
        return
    print(f"Build verified; quitting {app.name} (PID {', '.join(map(str, pids))})", flush=True)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 15
    while running_pids(app):
        if time.monotonic() >= deadline:
            raise RuntimeError(f"{app.name} did not quit; it was left running and the installation was not replaced")
        time.sleep(0.1)


def install(source: pathlib.Path, destination: pathlib.Path, replace: bool, dry_run: bool,
            skip_register: bool, restart: bool) -> None:
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
    if dry_run:
        print(f"Verified {source}")
        print(f"Would install to {destination}")
        if restart:
            print(f"Would quit any running {destination.name} and launch the installed app")
        return

    staging_root = pathlib.Path(tempfile.mkdtemp(prefix=f".{destination.stem}.install-", dir=destination.parent))
    staged = staging_root / destination.name
    backup = None
    try:
        shutil.copytree(source, staged, symlinks=True)
        verify_app(staged)
        if restart:
            quit_running(destination)
        elif running_pids(destination):
            raise RuntimeError(f"Quit {destination.name} before installing, or pass --restart to quit it after verification")
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
        print(f"Installed {destination}", flush=True)
        if backup is not None:
            print(f"Backup {backup}", flush=True)
        if restart:
            try:
                subprocess.check_call(["open", "-n", str(destination)])
            except (OSError, subprocess.CalledProcessError) as error:
                raise RuntimeError(f"Installed to {destination}, but launch failed: {error}") from error
    finally:
        shutil.rmtree(staging_root, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=pathlib.Path, default=ROOT / "dist/release" / APP_NAME)
    parser.add_argument("--destination", type=pathlib.Path, default=pathlib.Path("/Applications") / APP_NAME)
    parser.add_argument("--replace", action="store_true", help="Replace an existing app and retain a backup")
    parser.add_argument("--dry-run", action="store_true", help="Verify without changing the destination")
    parser.add_argument("--skip-register", action="store_true", help="Do not update LaunchServices")
    parser.add_argument("--build", action="store_true", help="Build and sign a fresh Release before installing")
    parser.add_argument("--ffmpeg", help="Explicit FFmpeg input matching Dependencies.lock.json")
    parser.add_argument("--restart", action="store_true", help="Quit the old app only after verification, then launch the installed app")
    args = parser.parse_args()
    build = None
    try:
        if args.build and args.dry_run:
            raise RuntimeError("--build cannot be combined with --dry-run")
        if args.ffmpeg and not args.build:
            raise RuntimeError("--ffmpeg requires --build")
        source = args.source
        if args.build:
            build_root = ROOT / ".build"
            build_root.mkdir(exist_ok=True)
            build = tempfile.TemporaryDirectory(prefix="local-install-", dir=build_root)
            source = pathlib.Path(build.name) / APP_NAME
            command = [sys.executable, str(ROOT / "scripts/bundle.py"), "--output", str(source)]
            if args.ffmpeg:
                command += ["--ffmpeg", args.ffmpeg]
            print(f"Building and signing {source}; the running app will not be interrupted", flush=True)
            subprocess.check_call(command)
        install(source, args.destination, args.replace, args.dry_run, args.skip_register, args.restart)
    except (OSError, RuntimeError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"Install failed: {error}", file=sys.stderr)
        return 1
    finally:
        if build is not None:
            build.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
