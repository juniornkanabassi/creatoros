# CreatorOS architecture check-in, 5 November 2026

## Pipeline actions and bounded file work [Strong]

Files: `AppModel.swift` (1,389 lines before the change), `AppModel+Pipeline.swift`, `BackgroundFileOperations.swift`.

Signal: AppModel owns presentation, workflow and filesystem work. Pipeline actions and Finder tag scheduling are a cohesive section with their own state and tests. Template removal and relink-root probing perform blocking filesystem work on the main actor.

Proposal: keep AppModel as the observable owner and retain its single writer slot. Move pipeline actions into one extension. Run template Trash/restore and relink-root probing through a stateless background service with captured values. Keep mutations and result publication on the main actor.

Benefits: pipeline rules are in one file; slow filesystem calls do not block the interface. The GUI and all control commands retain the same business methods. No library format or data ownership changes.

Proof: existing CoreChecks and control-model tests cover board rules, writer ownership, rename, metadata and hidden locations. Add disposable checks for root selection and restoration without overwriting. The full packaged/headless suite remains the integration gate.

Plan: first extract pipeline actions without changing them; then move bounded file work and add focused checks. The parent session runs builds and existing suites after integration.

## Considered, not recommended for this patch

- A second observable pipeline store would introduce another state owner and require broad GUI and CLI changes around the writer slot. Keep one state owner for this audit fix.
- Asynchronous startup loading changes when defaults, the library and control server become available. It needs its own loading/error-state design and cold-start tests.
- Icon decoding uses AppKit and is reached through a synchronous control API. Move it only with an explicit end-to-end async command change.
- The remaining relink commit checks and schema-upgrade validation are correctness boundaries. Do not move them speculatively.

Top recommendation: extract the cohesive actions and offload only bounded file operations. This is the selected Strong recommendation for the unattended implementation.
