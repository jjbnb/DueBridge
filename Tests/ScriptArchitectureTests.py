#!/usr/bin/env python3
"""Exercise test-host architecture selection through the real shell scripts."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ScriptArchitectureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="duebridge-script-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        source_root = Path(__file__).resolve().parents[1]
        for name in ("common.sh", "source-files.sh", "test.sh"):
            shutil.copy2(source_root / "scripts" / name, scripts / name)
        self.sdk = self.root / "MacOSX.sdk"
        self.sdk.mkdir()
        self.capture = self.root / "compiler-arguments"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.write_command(
            "uname",
            'case "$1" in\n'
            '  -s) printf "%s\\n" Darwin ;;\n'
            '  -m) printf "%s\\n" "$SCRIPT_TEST_HOST_ARCH" ;;\n'
            '  *) exit 2 ;;\n'
            "esac\n",
        )
        self.write_command(
            "xcrun",
            'printf "%s\\0" "$@" >> "$SCRIPT_TEST_COMPILER_ARGUMENTS"\n',
        )

    def write_command(self, name, body):
        command = self.bin / name
        command.write_text("#!/bin/bash\nset -euo pipefail\n" + body)
        command.chmod(0o755)

    def environment(self, host_arch, requested_arch=None):
        env = os.environ.copy()
        env.pop("DUEBRIDGE_TEST_ARCH", None)
        env.update(
            PATH=str(self.bin) + os.pathsep + env.get("PATH", os.defpath),
            DUEBRIDGE_SDK=str(self.sdk),
            SCRIPT_TEST_HOST_ARCH=host_arch,
            SCRIPT_TEST_COMPILER_ARGUMENTS=str(self.capture),
        )
        if requested_arch is not None:
            env["DUEBRIDGE_TEST_ARCH"] = requested_arch
        self.capture.unlink(missing_ok=True)
        return env

    def run_typecheck(self, host_arch, requested_arch=None):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts/test.sh"), "typecheck"],
            env=self.environment(host_arch, requested_arch),
            capture_output=True,
            text=True,
            timeout=10,
        )

    def assert_compiler_target(self, result, target):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.capture.exists(), "typecheck did not invoke the compiler")
        arguments = self.capture.read_bytes().decode().split("\0")[:-1]
        self.assertEqual(
            arguments[:11],
            [
                "swiftc", "-sdk", str(self.sdk), "-target", target,
                "-swift-version", "5", "-module-cache-path",
                str(self.root / "build/module-cache"), "-typecheck", "-parse-as-library",
            ],
        )
        self.assertEqual(arguments.count("-target"), 1)

    def assert_rejected_before_compile(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr.strip(), "architecture rejection needs a diagnostic")
        self.assertFalse(self.capture.exists(), "a rejected architecture invoked the compiler")

    def test_default_arm_host_typechecks_for_arm(self):
        self.assert_compiler_target(self.run_typecheck("arm64"), "arm64-apple-macosx14.0")

    def test_explicit_arm_host_typechecks_for_arm(self):
        self.assert_compiler_target(
            self.run_typecheck("arm64", "arm64"), "arm64-apple-macosx14.0"
        )

    def test_explicit_intel_host_typechecks_for_intel(self):
        self.assert_compiler_target(
            self.run_typecheck("x86_64", "x86_64"), "x86_64-apple-macosx14.0"
        )

    def test_default_intel_host_is_rejected_before_compile(self):
        self.assert_rejected_before_compile(self.run_typecheck("x86_64"))

    def test_requested_architecture_must_match_native_host(self):
        for host, requested in (("arm64", "x86_64"), ("x86_64", "arm64")):
            with self.subTest(host=host, requested=requested):
                self.assert_rejected_before_compile(self.run_typecheck(host, requested))

    def test_unsupported_architectures_are_rejected_before_compile(self):
        for requested in ("i386", "", "x86_64-apple-macosx14.0"):
            with self.subTest(requested=requested):
                self.assert_rejected_before_compile(self.run_typecheck("arm64", requested))

    def test_application_flags_ignore_test_architecture(self):
        for requested in ("arm64", "x86_64", "i386"):
            with self.subTest(requested=requested):
                result = subprocess.run(
                    [
                        "/bin/bash", "-c",
                        'source "$1"; xcrun swiftc "${FLAGS[@]}" -typecheck -parse-as-library',
                        "common-flags", str(self.root / "scripts/common.sh"),
                    ],
                    env=self.environment("x86_64", requested),
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assert_compiler_target(result, "arm64-apple-macosx14.0")


if __name__ == "__main__":
    unittest.main()
