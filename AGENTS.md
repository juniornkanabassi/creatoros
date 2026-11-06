# Shared source entrypoint

Read `../AGENTS.md`, `../00 Project State/MEMORY.md`, the latest entry in `../00 Project State/Validation.md` and `docs/DEVELOPMENT.md` before editing. Those are the shared instructions and current state for every assistant. No separate handoff procedure is needed. Do not start a parallel implementation elsewhere.

Reviews here follow the JuniorOS `03 Skills/Review workflow.md`. This project's own delta is `REVIEW.md`. Name that file in every review brief, because the local `/code-review` does not read `REVIEW.md` by itself.

Tests and launch checks must never show windows or take focus: the TestOffscreen guard is a dependency of every test target, and real-app checks pass the invisible flag. Never use open, computer use or a visible Simulator in tests (6 Nov 2026).

After meaningful work, update the existing memory and validation record automatically. Build with `zsh build.sh`; run the CoreChecks executable using the instructions in `docs/DEVELOPMENT.md`. Do not install over a running app or modify a user's library without a backup and an explicit in-scope reason.
