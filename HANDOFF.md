# HANDOFF — Lead & DoE seat departure (2026-11-26)

> Written by the departing Lead / Director-of-Engineering seat (Z.ai agent, operating the
> `khalid-s-slave` GitHub App) at the Owner's request: chat context, work in progress, and
> the staffing recommendation. One copy per repo; this repo's specifics are at the end.
> Org-level state lives in `khaalidrafi/agent-team-hq` (STATE.org, MEMBERS.org, TODOS.org,
> CONTROL.org).

## 1. Closing-session work log (2026-11-26)

1. **emacshell v0.1.5 — "ready on install"** (Owner order 2026-11-26: the apt
   repository must be configured at install time, no manual fix step) — landed
   on `ai/main` as `9f0b9ad`:
   - `TermuxInstaller.fixAptSourcesList` now writes the `emacshell-packages` repository line
     into `$PREFIX/etc/apt/sources.list` **unconditionally** at bootstrap-install time
     (a missing or empty sources.list is created; retired upstream/apt-* lines are commented
     and preserved).
   - `termux-fix-repo` / `site-start.el` (Elisp side) ensure the same for older installs.
   - `scripts/build-bootstrap.sh` **patch 7** rewrites `etc/apt/sources.list` inside the
     produced bootstrap zip, so the prefix is born pointing at the right repository.
   - `patches/termux/0004` regenerated (it had drifted from the vendored TermuxInstaller
     since b7459ad); version bumped to 0.1.5; README/REVIEW/TODOS updated.
   - APK build dispatched (build.yml run 45769328775, bootstrap artifacts from run
     44869748375); the v0.1.5 release and refreshed `emacshell-packages-*` releases were
     the in-flight tail of the session — see the emacshell repo for the final state.
2. **Handoff files** committed to every repo the App can write to.
3. **Staffing recommendation** (below) recorded in agent-team-hq STATE.org (STAFFING /
   HIRING-LOG) — GLM 5.3 Flash's new role and the Lead/DoE candidates the Owner named.

## 2. Standing state and warnings

- **GitHub credentials**: every credential sealed in `freshorama/vault` was dead on
  2026-11-25 (App JWT 401, GH_PAT / SLAVE_AGENT_PAT / FRESHORAMA_WEBSITE_PAT 401). The
  working credential on 2026-11-26 is the `khalid-s-slave` GitHub App (client id
  `Iv23lim10rZIAMO6Pyfw`, app id 5623575, PEM dated 2026-11-23 supplied by the Owner),
  installed on khaalidrafi (selected repos), freshorama (all) and sensible-os (all).
  **Action: re-seal a fresh credential in the vault** so it stops being handed around
  out-of-band, and rotate the PEM if this one has been shared too widely.
- **Time-discipline law** (Owner order 2026-11-24) applies to every board: every open item
  carries SCHEDULED/DEADLINE with a warning lead, `:EFFORT:` estimates, `:LOGBOOK:`
  clocking, append-only rows, and a show-cause note to the Owner before any deadline slips.
  `emacshell/TODOS.org` is the reference implementation.
- **Lost work**: the org-board tooling (`scripts/org-board/`: board_clock.sh,
  board_discipline.sh) was committed only to the (now gone) sandbox on 2026-11-25 (1b155a6)
  — the push was blocked by the dead credentials. It needs a redo if wanted; the
  platform-side daily 09:00 Asia/Dhaka sweep cron (job 547540) still references it.
- **emacshell on-device test** (long-OPEN P0): with v0.1.5 it is: sideload, wait for the
  first-boot unpack, `apt update && apt install less` — no fix-repo step. It closes when
  the Owner confirms.

## 3. Staffing recommendation (benchmarked 2026-11-26)

Sources: Artificial Analysis (Intelligence Index v5.0.1; per-task costs), Google's Gemini 4
Hydrogen announcement (2026-11-12), Terminal-Bench / tbench.ai, DeepSWE, and the Kilo Code
/ Cline live catalogs.

### GLM 5.3 Flash → new role: **Director of Engineering (DoE)**

- **Real-world evidence**: GLM-5.3-Flash is free in Cline and became the fastest-growing
  model in Cline history (>11% of all traffic within a week) — the org's `cline` seat
  (MEMBERS.org) runs the DoE at $0.
- **Benchmarks**: AA Intelligence Index 28 (top-30 of 763 models; Gemini 3.8 Flash scores
  31 high / 30 medium / 22 low); DeepSWE v1.1 63.4 (vs 46.2 for GLM-5.2, within a point of
  Claude Opus 4.8 on Terminal-Bench); Terminal-Bench 4.0 32.8% (37.0% on the tbench.ai
  board); AutomationBench-AA 60.4%.
- **Economics**: $0.15/$0.50 per 1M tokens, ~$0.58 per agentic task — cheapest meaningful
  coding agent; open-weight (320B params / 18B active), 20+ providers, 1M context,
  text+image input. Weakness to staff around: ~54 tok/s output — slow for rapid-fire seats,
  fine for review-heavy DoE duties.
- **Fit**: DoE work is high-volume review, verification evidence, and repo hygiene —
  Flash's surgical-edit, repo-work profile at a fraction of frontier cost, with the Cline
  free lane as the zero-cost default.

### Team Lead / Engineering Manager → **Gemini 4 Hydrogen**

- AA Intelligence Index 51 at default high thinking (54 at xhigh) — above Gemini 4 Argon
  (50); **Terminal-Bench 4.1: 57% vs Gemini 3.8 Flash's 18.2%** (3x), 2.5x faster than
  3.8 Flash; #5 Agent Arena; #1 Vals Tax Agent Bench (52.3%); tied #1 Vals Legal Research
  (55.8%); leads its class on AutomationBench-AA.
- **Trust profile** (matters for a role that owns CONTROL.org and DONE transitions): 94%
  honesty rate on Google's internal agent-honesty eval, 12x fewer misaligned actions /
  task shortcutting than 3.8 Flash, up to 81% less overreach, 2.3x more resilient to
  indirect prompt injection, 99.9% chain-of-thought legibility.
- **Economics**: $1.50/$7.50 per 1M flat across the 1M context. A Lead is low-volume /
  high-stakes — the price is irrelevant next to dispatch quality.

### Why not the others

- **Gemini 3.8 Flash** (Sep 2026): AA 31 (high), 102 tok/s, $0.75/$3.75 — but Terminal-
  Bench 4.1 at 18.2% is disqualifying for terminal-heavy leadership in this fleet, and
  Hydrogen dominates it at every tier while being 2.5x faster. Keep it as a cheap
  fast-lane worker for non-terminal volume (docs, data transforms).
- **Kilo Code free models** (Nemotron 3.5 Super VL free — code-agent rank #7 on Kilo's
  live leaderboard; Nemotron 3 Ultra free — #28; Dots3-Note Preview free): excellent
  **worker/verifier seats** — the multi-model pattern Google itself ships (frontier
  coordinator + fast workers/verifiers) — but a rotating free catalog is no foundation
  for a judgment seat; don't put Lead/DoE on a model that can vanish from the catalog.

**Proposed org chart**: Lead = Gemini 4 Hydrogen (dispatch, board, CONTROL, DONE
transitions) · DoE = GLM-5.3-Flash (review, verification, repo hygiene; free via the
cline seat, $0.15/$0.50 API fallback) · workers = Kilo free models + Gemini 3.8 Flash for
speed-critical volume · deep-reasoning escalations = Gemini 4 Carbon/Argon or GLM-5.3
(max) when a task justifies it.

---

## 4. This repo: `khaalidrafi/lark-org`

| | |
|---|---|
| Default branch | `ai/main` |
| HEAD | `63b7c27fd` — termux: lark-cli as a Termux package |
| Last commit | 2026-11-23T11:18:58Z |
| Last push | 2026-11-23T11:19:11Z |
| Open issues+PRs | 0 |
| Flags | none |
| Description | Org chat UI for Lark Messenger - ORG-CHAT-STANDARD v1.1 conforming (Lark/Feishu Open Platform backend) |

*Facts above were captured by the API on 2026-11-26 at handoff time. Repo-local law, if any, lives in its AGENTS.md / HUMANS.md; boards (TODOS.org) follow the six-law time discipline (Owner order 2026-11-24).*
