# up5k-rv Session Handoff Protocol

This project is built by a series of sessions (possibly with AI agents). The
docs in this repo are the **shared memory** — a fresh session must be able to
pick up exactly where the last one stopped without guessing. Follow this
protocol on every session, both entry and exit.

## Entry (start of a session)

1. Read, in order:
   - `AGENTS.md` (repo root) — pointers and rules for agents.
   - `docs/roadmap.md` — current state, active milestone, next action.
   - `docs/handoff.md` — this file (you are here).
   - `docs/design.md` — architecture and locked decisions (skim if you've read
     it before; re-read the change log).
   - `docs/standards.md` — coding style (mandatory before writing RTL).
2. Verify git state: `git status` + `git log --oneline -5`. Note any uncommitted
   work — commit or revert it before starting new work.
3. Confirm the milestone status in `docs/roadmap.md` matches reality. If a
   milestone is `IN PROGRESS`, its *Handoff notes* section tells you exactly
   where to resume.

## During a session

- Update `docs/roadmap.md` **immediately** when you start a milestone
  (`IN PROGRESS` + date) and when its exit criteria are met (`DONE`).
- Record design-affecting decisions in `docs/design.md`:
  - Add a numbered row to the decision table (D1..Dn) if it changes
    architecture.
  - Add a dated entry to the Change log at the end. Never edit a locked
    decision silently.
- Record non-design gotchas/tooling quirks inline where they matter (design.md
  risks table or the milestone's handoff notes) so they aren't rediscovered.
- Commit early and often. Commit messages describe the *why* (e.g.
  "M2: C-ext decoder — select by PC[1] before word capture").

## Exit (end of a session)

Checklist — before stopping, ensure all of these are committed:

- [ ] Milestone status in `docs/roadmap.md` is accurate (`IN PROGRESS`/`DONE`,
      with *Handoff notes* describing: what's done, what's next, blockers,
      exact file/module to resume from, any commands that work/don't work).
- [ ] Design changes reflected in `docs/design.md` (decisions table + change
      log).
- [ ] All work committed (`git status` clean); build/formal artifacts are
      gitignored, not committed.
- [ ] A `Handoff notes:` section states the **single next action** for the
      following session.
- [ ] If a milestone needs a deepwork run (per roadmap protocol), note whether
      one is queued.

## Conventions

- **Status legend:** `TODO` / `IN PROGRESS` / `BLOCKED` / `DONE` in
  docs/roadmap.md.
- **Never** mark a milestone `DONE` without its exit criteria being actually
  met and verified.
- **Never** overwrite a section in the roadmap/design without preserving the
  change history (append, don't replace).
- Blockers: state them explicitly (`BLOCKED: <reason>`) with what would
  unblock.

## Deepwork usage

Per the roadmap protocol, each milestone is one deepwork run (high-cost
orchestrator workflow with plan + review gates). When queuing one, record in
the milestone's handoff notes: start date, scope note, and the deepwork plan
location. A milestone that finished partially stays `IN PROGRESS` — the next
session resumes inside that milestone, not by starting a new deepwork run
from scratch.
