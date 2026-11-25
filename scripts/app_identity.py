from pathlib import Path

BUNDLE_ID = "im.yufei.manping"
DEBUG_BUNDLE_ID = BUNDLE_ID + ".debug"
PERF_BUNDLE_ID = BUNDLE_ID + ".perf"
URL_SCHEME = "manpingx"
STORAGE_DIRECTORY_NAME = BUNDLE_ID

APP_NAME = "满屏.app"
DISPLAY_NAME = "满屏"
EXECUTABLE_NAME = "Manping"

LOCAL_SIGNING_NAME = "Manping Yufei Signing"
RELEASE_SIGNING_NAME = "Manping Yufei Release Signing"
RELEASE_SIGNING_DIRECTORY = Path.home() / "Library/Application Support/Manping Yufei Signing"
