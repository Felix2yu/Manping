#!/usr/bin/env python3
"""Build an isolated, pinned libmpv; never install into or overwrite Homebrew."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.42.0'
ARCHIVE_SHA = 'bcfebbfa2b65a6d88dc97ea18117831072373e38b5785a2afb874ed4df5070dd'
PATCHES = {
    'mpv-0.42.0-deduplicate-quad-coordinates.patch': '106dd6766887aead29b8cb5e10cec44702d29cf841d5d371c1b82618be9e16c6',
    'mpv-0.42.0-renderer-compatibility.patch': '328208843576f88888678e65ccaa440542d9a4b47adf0c682636098dbbb2d472',
    'mpv-0.42.0-swift-cametal-layer.patch': '2fc1d9004a3e1533f181e4918a2470eb114d72074eac9016d2920d9ca8d349c2',
}

def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)

def fresh_source(archive, work):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA:
        raise RuntimeError('Unexpected mpv source archive')
    if {name: hashlib.sha256((ROOT / 'patches' / name).read_bytes()).hexdigest() for name in PATCHES} != PATCHES:
        raise RuntimeError('Unexpected pinned mpv patch')
    work.mkdir(parents=True, exist_ok=True)
    source = work / f'mpv-{VERSION}'
    if source.exists(): shutil.rmtree(source)
    with tarfile.open(archive) as bundle:
        bundle.extractall(work, filter='data')
    for name in PATCHES:
        with (ROOT / 'patches' / name).open('rb') as data:
            run('patch', '--batch', '-p1', cwd=source, stdin=data)
    return source

def main():
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    work = ROOT / '.build/mpv-source'
    work.mkdir(parents=True, exist_ok=True)
    archive = work / f'mpv-v{VERSION}.tar.gz'
    if not archive.exists():
        urllib.request.urlretrieve(f'https://github.com/mpv-player/mpv/archive/refs/tags/v{VERSION}.tar.gz', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA:
        raise RuntimeError('Unexpected mpv source archive')
    patch_hashes = {name: hashlib.sha256((ROOT / 'patches' / name).read_bytes()).hexdigest() for name in PATCHES}
    if patch_hashes != PATCHES:
        raise RuntimeError('Unexpected pinned mpv patch')
    # Re-extract the verified archive every time. Reverse-applicability alone does not
    # establish that unrelated files in a reused source tree are clean.
    source = fresh_source(archive, work)
    environment = ROOT / '.build/mpv-tools'
    python = environment / 'bin/python'
    meson = environment / 'bin/meson'
    ninja = environment / 'bin/ninja'
    if not meson.exists() or not ninja.exists():
        if not python.exists():
            run('python3', '-m', 'venv', str(environment))
        run(str(environment / 'bin/pip'), 'install', 'meson==1.10.1', 'ninja==1.11.1.1')
    build_environment = dict(os.environ, PATH=str(environment / 'bin') + os.pathsep + os.environ['PATH'])
    lock = json.loads((ROOT / 'Dependencies.lock.json').read_text())
    ffmpeg = Path(lock['ffmpegExecutable']['source'])
    if hashlib.sha256(ffmpeg.read_bytes()).hexdigest() != lock['ffmpegExecutable']['sha256']:
        raise RuntimeError('Locked FFmpeg executable input SHA mismatch')
    pkg_config = ffmpeg.parent.parent / 'lib/pkgconfig'
    build_environment['PKG_CONFIG_PATH'] = str(pkg_config) + os.pathsep + build_environment.get('PKG_CONFIG_PATH', '')
    build = ROOT / '.build/mpv-build'
    if build.exists(): shutil.rmtree(build)
    options = ['-Dbuildtype=release', '-Dlibmpv=true', '-Dcplayer=false', '-Dbuild-date=false', '-Dmanpage-build=disabled', '-Dhtml-build=disabled', '-Dvapoursynth=disabled', '-Dmacos-cocoa-cb=disabled', '-Dvulkan=disabled', '-Dswift-flags=']
    setup = ['setup', str(build), str(source), *options]
    run(str(meson), *setup, env=build_environment)
    run(str(meson), 'compile', '-C', str(build), '-j', '8', env=build_environment)
    library = build / 'libmpv.2.dylib'
    run('lipo', '-verify_arch', 'arm64', str(library))
    metadata = {'version': VERSION, 'sourceSHA256': ARCHIVE_SHA, 'deduplicatedTextureCoordinates': True,
                'patches': patch_hashes, 'meson': '1.10.1', 'options': options,
                'librarySHA256': hashlib.sha256(library.read_bytes()).hexdigest()}
    (build / 'MpvBuild.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(library)

if __name__ == '__main__': main()
