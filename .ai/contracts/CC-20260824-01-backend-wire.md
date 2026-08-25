# Task contract: CC-20260824-01

## Outcome

Close real IRC/IRCX/TLS/session/DCC/UDI correctness and reliability gaps in
the portable backend against Microsoft Comic Chat wire behavior and a modern
Onyx TLS IRC server, without redesigning desktop UI.

## Route

- Score: `2 + 1 + 2 + 1 = 6`
- Primary lane: `balanced`
- Required reviewer: `frontier` (critical domain: protocol-compatibility, tls, credentials)
- Maximum parallel lanes: `3` (independent read-only scouts; one writer)
- Critical domain: `protocol-compatibility`

## Ownership

- Owned paths:
  - `src/net/` (IRC/IRCX, CAP/SASL, TLS, transport, session store, reconnect policy, client composition)
  - `src/proto/` (UDI, DCC, keystring, record only if wire-related)
  - `src/comic/session.zig` (NAMES/JOIN/PART roster and annotation consumption)
  - `src/comic/notify.zig` and `src/comic/rules.zig` only if they own WHO/LIST snapshot correctness that backend state depends on
  - focused tests aggregated from `src/root.zig`
  - protocol docs only if a closed gap changes a documented invariant
- Read-only dependencies:
  - `docs/WORKERS.md`, `docs/PROTOCOL.md`, `docs/MICROSOFT_WIRE_AUDIT.md`
  - `docs/audits/2026-07-22-comicchat-onyx-ircv3-parity.md`
  - IRCX draft 04, Microsoft source commit `c7df00f60bc8e9fdef413f139e61f7c37e024684`
  - `third_party/onyx-server` pinned revision
- Forbidden paths:
  - desktop UI chrome, layout, styling, menus, dialogs (`src/client/` view/chrome, `src/platform/*` except if a backend-owned DCC consent hook is already there)
  - renderer/layout/raster (`src/comic/original_*`, `strip.zig`)
  - asset files, golden raster hashes
- Base commit: `74b19bd1fc3dc07f252616f009dfabdc79011330` (current `main`)

## Evidence and constraints

- Existing behavior: docs claim exact IRCX discovery, UDI send/receive, PROP/ACCESS/LISTX, DCC consent, SASL, SESSION RESUME, reconnect restoration.
- Source/reference evidence: `ircproto.cpp`, `ircsock.cpp`, `protsupp.cpp`, IRCX draft 04, Onyx session/TLS contract.
- Invariants from `docs/WORKERS.md`:
  - no SDL; pinned Onyx TLS; no insecure fallback
  - no mutable protocol globals or detached worker ownership
  - parsed messages borrow framing storage
  - `client.zig` is the only live composition layer
  - DCC consent/progress owned by app; `client.zig` only serializes offers
  - only validated JOIN/NAMES/history atoms on reconnect; never replay uncertain PRIVMSG

## Acceptance criteria

- [x] Real correctness/reliability bugs in owned backend surfaces are fixed, not merely documented
- [x] Focused tests pin each closed gap
- [x] `zig build test` passes
- [x] `zig build` linux/amd64 still builds
- [x] `git diff --check` clean
- [x] PR lists what was fixed and honest leftovers
- [x] No desktop UI redesign

## Wave 9 leftovers in scope

- Delay NICK/USER until CAP END when SASL credentials are present
- Exception/invite list MODE +e/+I on the existing ban-dialog / channel-mode path; show 346-349
- Rejoin workspace rooms that restoration does not already cover
- Show remaining live numerics 329 and send failure 486

## Verification

- Focused gate: new/updated inline tests in owned modules
- Aggregate gate: `zig build test`
- Build gate: `zig build` (linux/amd64)
- Hygiene gate: `git diff --check`

## Authority

- Local edits authorized: `yes`
- External writes authorized: `no` (PR creation is the only GitHub write, via required agent tooling)
- Destructive actions authorized: `no`

## Handoff

- Files changed:
- Commands and outcomes:
- Evidence:
- Residual risk:
- Recommendation: `accept | escalate | discard`
