#!/usr/bin/env python3
"""Build an isolated deterministic clock probe; never alter application source."""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = (root / "Sources/NativeWebSession.swift").read_text()
start = source.index("    private func startNavigationDeadline()")
end = source.index("    private func finishNavigation(", start)
fragment = source[start:end]
sleep = "try await Task.sleep(nanoseconds: 45_000_000_000)"
assert fragment.count(sleep) == 1, "expected one navigation-only sleep seam"
fragment = fragment.replace(sleep, "try await ControlledNavigationClock.sleep()")
stop = "self.webView?.stopLoading()"
assert fragment.count(stop) == 1, "expected one navigation timeout stop branch"
fragment = fragment.replace(stop, "ControlledNavigationClock.stopAttempts += 1; " + stop)
source = source[:start] + fragment + source[end:]
source += "\n" + (root / "Tests/NativeNavigationDeadlineTests.swift").read_text()
destination = root / "build/navigation-probe/NativeWebSessionProbe.swift"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(source)
