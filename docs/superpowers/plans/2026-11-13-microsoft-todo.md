# Microsoft To Do Implementation Plan

> **For agentic workers:** Use isolated implementation of the Graph client, then independent spec/quality review and whole-feature review. Continue the user's authorized implementation without additional approval gates.

**Goal:** Add an optional To Do destination to the Windows preview without disrupting desktop or Outlook behavior.
**Architecture:** Reuse the Graph assembly and per-resource MSAL permissions; keep separate destination bindings, write consent and checkpoints in encrypted workspace settings. One source refresh fans out independently to both cloud destinations. A durable creation journal prevents blind repeated POST after ambiguous results.
**Tech Stack:** Existing .NET 10/WPF, Microsoft Graph v1.0, MSAL and current-user DPAPI.
**Spec:** `docs/superpowers/specs/2026-11-13-microsoft-todo-design.md`.

## Global constraints
- Three existing sources; personal Microsoft accounts; same public application ID.
- Keep date-only task due dates plus exact Beijing deadline in managed task details.
- Preserve user completion, notes, importance, reminders and checklist items.
- Local-only refresh never writes cloud; global pause blocks both destinations.
- Do not publish private sources or actual school/session data; new preview is chronological package 04.

## Review focus
- Lost create responses and cancellation must leave a durable guard until recovered or explicitly cleared.
- A different Microsoft/source account must not inherit consent or pending operations.
- A failed destination must not discard local reads or block the other target.
- A completed task or concurrent personal note must not be reopened/overwritten.
- Legacy settings must load with To Do off, keeping existing Outlook and desktop setup.

### Task 1: Graph client (isolated implementation)
Files: new `Windows/DueBridge.Outlook/TodoTypes.cs`, `TodoTasks.cs`, `TodoTaskProjection.cs`; new `Windows/DueBridge.Outlook.Tests/TodoTests.cs`.
Interfaces: `TodoListBinding(OutlookAccount Account,string ListId)`; `ITodoWriteJournal` with `IsPending(string)`, `Begin(string,string description)`, `Complete(string)`; `TodoTasks.CreateListAsync`, `SyncAsync`, `PendingPrefix(OutlookAccount)`; reuse `CalendarSyncResult`.
- [x] Add failing fake-HTTP tests for marked list creation, lost responses, duplicate IDs, pagination, note/completion retention, source isolation and pending journal.
- [x] Implement least-privilege Graph requests with stable hashed management properties, bounded pagination/response handling and no automatic repeated ambiguous POST.
- [x] Run tests; independent reviewer checks client contract and safety.

### Task 2: Destination integration
Files: existing `OutlookSignIn.cs`, `WorkspaceState.cs`, `WorkspaceRefresh.cs`, `MainWindow.xaml(.cs)`; new `MainWindow.Todo.cs`, `SettingsTodoJournal.cs`; extend portable tests.
- [x] Write failing state/refresh tests for upgrade defaults, separate consent/checkpoints, independent failures, source switch, pause and cancellation.
- [x] Add per-resource authorization using Tasks.ReadWrite only for To Do. Keep existing calendar default signatures compatible.
- [x] Add To Do settings/list creation, source consent, journal resolution for actual uncertain operations, and independent status.
- [x] Run portable suites, cross-publish and independent whole-feature review.

### Task 3: Delivery
- [x] Update Windows guide, privacy, changelog, README and allowlist; run all applicable suites and audit.
- [x] Package `04_归期-Windows_<build date/time>_ToDo预览.zip`, retain the registered public app ID, verify archive and x64 assembly.
- [ ] Push reviewed candidate branch, follow macOS/Windows CI; hand off real Microsoft authorization on Windows for user acceptance.

Verification: 23 To Do HTTP scenarios, permission/state and four independent destination scenarios, previous desktop/Graph suites, school C#/JS and core suites passed. Windows x64 cross-publish passed. Review fixes cover exact seconds and UTC due-date equivalence; native account consent is pending user acceptance.
