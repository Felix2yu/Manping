#!/usr/bin/env python3
"""Reuse the sealed runtime closure for a local UI Debug app; never rebuild libmpv."""
import argparse
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from resource_bundles import copy_resource_bundles  # noqa: E402
from app_identity import (
    APP_NAME,
    BUNDLE_ID,
    DEBUG_BUNDLE_ID,
    DISPLAY_NAME,
    EXECUTABLE_NAME,
    LOCAL_SIGNING_NAME,
    URL_SCHEME,
)
from debug_build_fingerprint import source_manifest, write_build_record  # noqa: E402


def signing_identity():
    """A stable local code-signing certificate keeps Keychain approvals across rebuilds.

    Ad-hoc signatures change with every build, so macOS treats each build as a new app and asks
    for the Keychain password again. Use MANPING_SIGN_IDENTITY or the self-signed local certificate
    documented in docs/Signing.md; otherwise fall back to ad-hoc signing.
    """
    explicit = os.environ.get("MANPING_SIGN_IDENTITY")
    if explicit:
        return explicit
    listed = subprocess.run(["security", "find-identity", "-p", "codesigning"],
        capture_output=True, text=True).stdout
    return LOCAL_SIGNING_NAME if f'"{LOCAL_SIGNING_NAME}"' in listed else "-"

def run(*args, capture=False):
    if capture:
        return subprocess.check_output(args, text=True).strip()
    subprocess.check_call(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=pathlib.Path,
                        default=ROOT / "dist/release" / APP_NAME)
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()
    os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    template = args.template.resolve()
    app = ROOT / ".build/ui" / (DISPLAY_NAME + " Debug.app")
    if not (template / "Contents/Frameworks/libmpv.2.dylib").is_file():
        raise RuntimeError("A bundled runtime template with libmpv.2.dylib is required")
    if template == app.resolve():
        raise RuntimeError("Template cannot be the Debug output")
    manifest = source_manifest(ROOT)
    if not args.no_build:
        run("swift", "build", "--disable-automatic-resolution")
        if source_manifest(ROOT) != manifest:
            raise RuntimeError("Build inputs changed during swift build; rebuild before capturing")
    binary_directory = pathlib.Path(run("swift", "build", "--show-bin-path", capture=True))
    if app.exists():
        shutil.rmtree(app)
    shutil.copytree(template, app)
    executable = app / "Contents/MacOS" / EXECUTABLE_NAME
    shutil.copy2(binary_directory / EXECUTABLE_NAME, executable)
    resources = app / "Contents/Resources"
    copy_resource_bundles(binary_directory, resources)
    # The Release executable manifest does not describe this local Debug executable.
    (resources / "BundleManifest.json").unlink(missing_ok=True)
    shutil.copy2(ROOT / "Resources/AppIcon/AppIconDebug.icns", resources / "AppIcon.icns")
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleDisplayName"] = DISPLAY_NAME + " Debug"
    info["CFBundleIdentifier"] = DEBUG_BUNDLE_ID
    info["CFBundleIconFile"] = "AppIcon"
    info["CFBundleIconName"] = "AppIcon"
    info["CFBundleURLTypes"] = [{"CFBundleURLName": BUNDLE_ID + ".link", "CFBundleURLSchemes": [URL_SCHEME],
        "CFBundleTypeRole": "Viewer"}]
    with (app / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    write_build_record(app, manifest, verified=not args.no_build)
    run("codesign", "--force", "--sign", signing_identity(), str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    if args.no_build:
        print("Source freshness unverified (--no-build); in-app capture requires a full build.")
    print(app)
    print("Launch: open -n " + str(app) + " --args --skip-auth --ui-page popular")


if __name__ == "__main__":
    main()
