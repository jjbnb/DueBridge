# Windows Desktop Card Implementation Plan

> **For agentic workers:** Implement natively in the current session as requested; use test-driven development and a final independent code review.

**Goal:** Display all three existing course sources in a persistent, draggable Windows desktop card without requiring Outlook.

**Architecture:** Add a portable workspace model for encrypted snapshots and independent read/write consent. Reuse the existing single-flight operation and minute timer; a separate WPF window consumes the same snapshots and timer. Keep Outlook writes separately gated and preserve previous settings on upgrade.

**Tech Stack:** Existing .NET 10, WPF, current-user DPAPI, Win32 monitor work areas; no new runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-11-12-windows-desktop-card-design.md` (approved 2026-11-13).

## Global Constraints

- Windows 11 x64; all three existing sources; Beijing-midnight daily checks.
- Default card 360×480 DIP, pin off, no completion checkboxes.
- Preserve school sessions, BB address, Outlook account/calendar and prior write consent.
- Snapshot contains normalized display fields, account scope and read time, never raw source notes or tokens.
- Manual card refresh reads bound sources only and never writes Outlook. Global pause blocks background reads and all calendar writes.
- Ordinary independent window: main-window minimization does not hide it; exiting the application closes it.

## Review Focus

- Legacy settings missing new properties: upgrade defaults safely, retains previous write consent.
- Same task ID in different sources/accounts: snapshots never overwrite or expose another scope.
- Successful read followed by failed Outlook write: keep fresh snapshot and separate success timestamps.
- Removed monitor/non-finite stored geometry: restore card inside an available monitor work area.
- Logout, cancellation, or changed account during refresh: prevent stale scope from writing or becoming current.

### Task 1: Portable workspace state

**Files:** New `Windows/DueBridge.Windows/WorkspaceState.cs`; modify `LocalSettings.cs`; new linked `Windows/DueBridge.Outlook.Tests/DesktopStateTests.cs` and test project entry; small normalization helper in `DueBridge.Core/DeadlinePresentation.cs`.

**Interfaces:** `LocalSettings.AcceptPreview(SourceKind, SourcePreview, string?, DateTimeOffset)` saves a sanitized, scope-bound `SourceSnapshot`; `DesktopEntries()` merges/sorts valid snapshots; `RefreshIntent.For(...)` gates independent reads/writes; `DesktopBounds.Fit(...)` clamps native-pixel bounds.

- [x] Write behavior tests for legacy JSON, local-only refresh, manual no-write, pause, snapshot replacement/scope/deduplication, safe text, account changes, separate read/write timestamps and geometry.
- [x] Run the tests and confirm missing behavior fails.
- [x] Implement the state and normalization; preserve DPAPI store and existing public-client configuration.
- [x] Run portable core, school and Outlook/desktop checks.

### Task 2: Integrate reading and desktop window

**Files:** New linked `WorkspaceRefresh.cs` and `DesktopRefreshTests.cs`; modify `MainWindow.xaml.cs`, `MainWindow.xaml`, `App.xaml.cs` as needed; new `MainWindow.Desktop.cs`, `DesktopCard.xaml`, `DesktopCard.xaml.cs`.

**Interfaces:** Main window remains the lifetime owner without setting WPF `Owner` on the card. Card accepts sorted display rows/status and exposes refresh/open callbacks; existing timer updates countdowns. Window placement saves on end-of-move, pin, hide and exit.

- [x] Split local daily read schedule from Outlook write schedule; persist a successful read before attempting cloud writes, retain snapshots on failure and cancellation.
- [x] Add per-source desktop auto-read control, card opener and explicit read/write status; preserve Outlook gating and all existing event handlers.
- [x] Implement compact keyboard-accessible card, pin, resize, work-area clamping and stored visibility; close card on app exit, restore it at startup.
- [x] Cross-build WPF for win-x64, run all Windows tests, independently review state/lifecycle integration and fix material findings.

### Task 3: Deliver preview

**Files:** Update `docs/windows.md`, `PRIVACY.md`, `CHANGELOG.md`, CI step labels and local publication allowlist.

- [x] Document local refresh versus Outlook, desktop/window lifetime, campus-network requirement and acceptance steps.
- [x] Run all Windows suites, cross-publish, archive integrity and publication audit; confirm no personal data in source.
- [ ] Commit and push the authorized candidate branch, follow both GitHub checks to completion.
- [x] Package a personalized Windows preview retaining the previously supplied public Microsoft app ID; report native Windows UI/DPAPI/live-login acceptance still required.

## Execution record

Local core/school/desktop/Graph tests and five school JavaScript checks pass. The full macOS suite passes with existing Keychain deprecation warnings. Independent review found a canceled-attempt scheduling defect; the fix preserves successful checkpoints and adds two cancellation recovery scenarios (nine refresh scenarios total). Native Windows display/scale and live-school acceptance remain manual.
