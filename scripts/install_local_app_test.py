#!/usr/bin/env python3
"""Verify that local installation never interrupts the old app before the new build is ready."""
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import install_local_app as installer


class InstallOrderTests(unittest.TestCase):
    def test_build_finishes_before_install_starts(self):
        events = []

        def build(*arguments):
            events.append("build")

        def install(*arguments, **keywords):
            events.append("install")
            self.assertTrue(arguments[-1])

        with mock.patch.object(sys, "argv", ["install_local_app.py", "--build", "--replace", "--restart"]), \
             mock.patch.object(installer.subprocess, "check_call", side_effect=build), \
             mock.patch.object(installer, "install", side_effect=install):
            self.assertEqual(installer.main(), 0)
        self.assertEqual(events, ["build", "install"])

    def test_explicit_ffmpeg_is_forwarded_to_bundler(self):
        commands = []

        def build(command):
            commands.append(command)

        ffmpeg = "/opt/homebrew/Cellar/ffmpeg/9.1/bin/ffmpeg"
        with mock.patch.object(sys, "argv", ["install_local_app.py", "--build", "--ffmpeg", ffmpeg]), \
             mock.patch.object(installer.subprocess, "check_call", side_effect=build), \
             mock.patch.object(installer, "install"):
            self.assertEqual(installer.main(), 0)
        self.assertEqual(commands[0][-2:], ["--ffmpeg", ffmpeg])

    def test_ffmpeg_requires_a_fresh_build(self):
        with mock.patch.object(sys, "argv", ["install_local_app.py", "--ffmpeg", "/tmp/ffmpeg"]), \
             mock.patch.object(installer.subprocess, "check_call") as build, \
             mock.patch.object(installer, "install") as install:
            self.assertEqual(installer.main(), 1)
        build.assert_not_called()
        install.assert_not_called()

    def test_failed_build_does_not_attempt_installation(self):
        with mock.patch.object(sys, "argv", ["install_local_app.py", "--build", "--replace", "--restart"]), \
             mock.patch.object(installer.subprocess, "check_call",
                               side_effect=subprocess.CalledProcessError(1, "bundle.py")), \
             mock.patch.object(installer, "install") as install:
            self.assertEqual(installer.main(), 1)
        install.assert_not_called()

    def test_staged_app_is_verified_before_old_process_is_quit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "Source.app"
            destination = root / "Target.app"
            source.mkdir()
            destination.mkdir()
            (source / "marker").write_text("new")
            (destination / "marker").write_text("old")
            events = []

            def verify(app):
                events.append(("verify", app))

            def quit_app(app):
                events.append(("quit", app))

            with mock.patch.object(installer, "verify_app", side_effect=verify), \
                 mock.patch.object(installer, "quit_running", side_effect=quit_app), \
                 mock.patch.object(installer.subprocess, "check_call") as launch:
                installer.install(source, destination, replace=True, dry_run=False,
                                  skip_register=True, restart=True)

            launch.assert_called_once_with(["open", "-n", str(destination)])
            self.assertEqual([event[0] for event in events], ["verify", "verify", "quit"])
            self.assertEqual(events[1][1].parent.parent, destination.parent)
            self.assertEqual((destination / "marker").read_text(), "new")
            backups = list(root.glob(".Target.backup-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual((backups[0] / "marker").read_text(), "old")

    def test_failed_staged_verification_leaves_old_app_and_bundle_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "Source.app"
            destination = root / "Target.app"
            source.mkdir()
            destination.mkdir()
            (destination / "marker").write_text("old")
            checks = 0

            def verify(app):
                nonlocal checks
                checks += 1
                if checks == 2:
                    raise RuntimeError("invalid staged app")

            with mock.patch.object(installer, "verify_app", side_effect=verify), \
                 mock.patch.object(installer, "quit_running") as quit_app:
                with self.assertRaisesRegex(RuntimeError, "invalid staged app"):
                    installer.install(source, destination, replace=True, dry_run=False,
                                      skip_register=True, restart=True)
            quit_app.assert_not_called()
            self.assertEqual((destination / "marker").read_text(), "old")
            self.assertFalse(list(root.glob(".Target.backup-*")))

    def test_running_app_still_requires_explicit_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "Source.app"
            destination = root / "Target.app"
            source.mkdir()
            destination.mkdir()
            with mock.patch.object(installer, "verify_app"), \
                 mock.patch.object(installer, "running_pids", return_value=[42]), \
                 mock.patch.object(installer, "quit_running") as quit_app:
                with self.assertRaisesRegex(RuntimeError, "pass --restart"):
                    installer.install(source, destination, replace=True, dry_run=False,
                                      skip_register=True, restart=False)
            quit_app.assert_not_called()


if __name__ == "__main__":
    unittest.main()
