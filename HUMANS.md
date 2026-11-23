# HUMANS.md

A guide for human developers who did not write this code and want to
understand, navigate, and safely develop it. Written from a fresh read
of the sources (2026-11-18). Everything below is verifiable in the
files named.

## What this is

lark-org is a single-file Emacs Lisp package (`lark-org.el`, ~1560
lines) that renders Lark Messenger (or Feishu) chats as read-mostly
Org buffers. It follows ORG-CHAT-STANDARD v1.1, a spec kept in the
sibling repo khaalidrafi/telega-org (file ORG-CHAT-STANDARD.org). Two
surfaces exist:

- `*Lark Org*` is the chat list: level-1 headings are groups, each chat
  is a level-2 heading with `:unread:N:` / `:mention:N:` tags plus one
  preview line (time, in/out arrow, one-line text).
- `*Lark Org: <chat>*` is one conversation: a level-1 entry with a
  `:CHAT-ID:`/`:KIND:` property drawer, then one level-2 entry per
  message with an inactive timestamp, author, tags, a `:PROPERTIES:`
  drawer (`:MSG-ID:`, `:AUTHOR:`), and an indented body.

The backend is the Lark Open Platform REST API, reached through
built-in url.el only. There is no backend package dependency and the
`Package-Requires` line is just `((emacs "28.1"))`. The package was
extracted verbatim from khaalidrafi/emacs-purple (see AI-REVIEW.org
for provenance and gate evidence).

## Mental model

The code is layered bottom-up; each layer only knows the one below it:

1. Transport and auth. `lark-org--http-url` wraps
   `url-retrieve-synchronously` and is swappable via the
   `lark-org-http-function` defcustom (the seam the tests stub).
   `lark-org--token` caches a tenant_access_token in memory,
   `lark-org--api-call` sends it as a Bearer header and retries once
   with a fresh token when the API answers one of the token-error
   codes.
2. Pure converters. Lark JSON items become plain plists:
   `lark-org--index-from-items` (chats), `lark-org--message-from-item`
   (messages), `lark-org--decode-content` (content payload to text).
   These are pure functions of their input; tests pin their behavior.
3. Live adapters. `lark-org--live-index`, `lark-org--live-view`, and
   `lark-org--live-send` call the API through layer 1, convert through
   layer 2, and are themselves pluggable via `lark-org-index-function`,
   `lark-org-view-fetch-function`, and `lark-org-send-function`. Read
   paths degrade to deterministic fixtures (`lark-org--fixture-index`,
   `lark-org--fixture-view`) on any error. The send path is the one
   deliberate exception: it signals, it never pretends.
4. Renderers. `lark-org-render` (list) and `lark-org-view-render`
   (conversation) draw whole buffers as Org text from the plists, then
   make the buffer read-only, disable undo, and install a minor mode
   with the verbs (keys).
5. Read markers. Because the Lark chats endpoint has no unread or
   preview model, the package keeps its own: a per-chat marker (unix
   seconds of the newest message seen), persisted in
   `lark-org-read-state-file` and stamped whenever a view renders.
   `lark-org--enrich-chat` reads bounded history per chat on every
   list refresh to compute the unread count and the real preview.

Main data flow for a list refresh: `lark-org` -> `lark-org-render` ->
`lark-org--live-index` -> GET im/v1/chats -> pure conversion ->
per-chat `lark-org--enrich-chat` (bounded history read through
`lark-org-history-function`) -> Org headings. Opening a chat: RET ->
`lark-org-open-at-point` -> `lark-org-view-render` -> history read ->
stamp the read marker -> draw.

## The two routes and the CLI installer

`lark-org-route` picks the backend for every call:

- `api` (default): Lark Open Platform REST over the url.el transport
  seam, with a tenant token minted from the app id + auth-source
  secret. Pure elisp, so the Android port runs it unchanged.
- `cli` (v0.3): the official Lark CLI (`lark-cli`) under YOUR user
  identity -- no app, no app secret, no app-quota billing. One
  subprocess seam (`lark-org--cli-run`), stubbed in tests.

`M-x lark-org-cli-install` (v0.4) installs the CLI with no npm:
release lookup through the transport seam (GitHub API, skippable
by pinning a version with a prefix argument), tarball download
through `lark-org-cli-download-function` (default url-copy-file),
sha256 verification against the release checksums, and an in-Elisp
tar extraction (zlib gunzip when this Emacs has it, the `tar`
program otherwise). Default target: Termux `$PREFIX/bin`, else
`~/.local/bin` -- so route `cli` works on Android through Termux.
`M-x lark-org-cli-login` then runs the CLI's interactive login in a
term buffer. The `termux/` directory carries the same repack as a
termux-packages recipe (`lark-cli/build.sh`) plus a plain
`install.sh`.

## Code map

Everything lives in one file plus one test file.

| File / symbol | Role |
| --- | --- |
| `lark-org.el` | The whole package |
| `lark-org-http-function` (defcustom) | Transport seam; default `lark-org--http-url` over url.el |
| `lark-org-route` (defcustom) | Backend selector: `api` (url.el REST, default) or `cli` (lark-cli passthrough, v0.3) |
| `lark-org--cli-run`, `lark-org--cli-call` | Route `cli`'s one subprocess seam and the envelope unwrapper |
| `lark-org-cli-install`, `lark-org-cli-login` | No-npm installer (download + sha256 + tar) and the login front end (v0.4) |
| `lark-org--token`, `lark-org--fetch-token`, `lark-org--api-call` | tenant_access_token cache, refresh, and retry-once auth wrapper |
| `lark-org--index-from-items`, `lark-org--message-from-item`, `lark-org--decode-content`, `lark-org--encode-text-content` | Pure Lark-JSON to plist converters |
| `lark-org--live-index`, `lark-org--live-view`, `lark-org--live-send` | API-backed adapters behind their defcustom seams; reads signal the backend's reason (demo fixtures only under `lark-org-demo`), send signals |
| `lark-org--fixture-index`, `lark-org--fixture-view` | Deterministic offline fixtures used by tests and the `lark-org-demo` opt-in |
| `lark-org--read-state-ensure`, `lark-org--read-state-save`, `lark-org--stamp-read`, `lark-org--unread-count`, `lark-org--enrich-chat`, `lark-org--apply-unread` | The local read-marker / unread model (v0.2) |
| `lark-org-render`, `lark-org` | List buffer renderer and entry command |
| `lark-org-view-render`, `lark-org-view-append` | Conversation renderer and live-append primitive |
| `lark-org--view-message-block`, `lark-org--view-body`, `lark-org--heading-line`, `lark-org--preview-line` | Org text generators for messages, bodies, headings |
| `lark-org--first-tagged-position`, `lark-org--view-unread-watch`, `lark-org--view-clear-unread` | Tag scanning and the auto-clear of the unread marker |
| `lark-org-view-compose`, `lark-org-view-send-draft`, `lark-org-send` | Draft and send paths (rule 8) |
| `lark-org-list-mode`, `lark-org-view-mode`, `lark-org-touch-mode` | Minor modes carrying the keymaps |
| `test.el` | 51 ERT tests, transport stubbed, no network |
| `termux/` | Termux package (`lark-cli/build.sh`), `install.sh`, README |
| `Makefile` | `compile` and `test` targets |
| `README.org` | User-facing setup and disclosed limits |
| `AI-REVIEW.org`, `CANDIDATES.org` | Provenance, review gates, crew roles (context, not code) |

## Core algorithms

- Token cache and bounded retry. `lark-org--token` returns the cached
  tenant token while `(float-time)` is under `lark-org--token-expiry`;
  `lark-org--fetch-token` sets expiry to `expire` minus 300 seconds.
  `lark-org--api-call` checks the response code against
  `lark-org--token-error-codes` (99991661, 99991663, 99991668),
  drops the cache, and retries exactly once. There is no loop.
- Bounded history pagination. `lark-org--history-items` loops at most
  `lark-org-max-pages` (default 3) times, appending `items` from
  GET im/v1/messages sorted ByCreateTimeAsc, and stops early unless
  `has_more` is truthy and a non-empty `page_token` came back.
  Cost is bounded: at most 3 pages x `lark-org-page-size` (50) items
  per chat per refresh.
- Unread counting. `lark-org--unread-count` is a single linear scan
  over the message list counting messages whose `:time` is newer than
  the marker; undated messages never count. `lark-org--apply-unread`
  walks the list once and tags only the first message newer than the
  marker with the remaining count, the rest with `t`; the renderer
  then keeps only the first tagged one.
- Read-marker stamping. `lark-org--stamp-read` replaces the alist
  entry for the chat only when the new time is strictly greater than
  the stored one, so markers never move backwards. The file is read
  once per session and written with `with-temp-file`; a missing or
  corrupt file reads as no markers (never an error).
- First-seen baseline. In `lark-org--enrich-chat`, a chat with no
  marker yet gets its baseline stamped at the newest message and a
  zero count, so unread counting starts from the next refresh, not
  from the beginning of history.
- Content decoding. `lark-org--decode-content` parses the content
  string as JSON per message type: "text" reads the `text` field,
  "post" flattens the rich-text runs (`lark-org--post-run` turns `a`
  tags into Org links and `at` tags into @name), other types map to
  kind words via `lark-org--kind-words` (image -> "photo", etc.) and
  unknown types become "card".
- Drawer-lookalike protection. `lark-org--view-body` rewrites any
  body line starting with a colon by inserting a space after the
  colon, so backend text can never forge a `:PROPERTIES:` drawer.
  URLs become Org links by regexp replace.
- Adjacent-chat walk. `lark-org--adjacent-chat-position` walks
  outline headings directly (`outline-previous-heading` /
  `outline-next-heading`) until it finds a level-2 heading, with a
  special case walking backward out of the subtree that strictly
  contains the start position. The docstring explains why:
  `org-forward-heading-same-level` skips subtrees and does not cross
  group boundaries.

## Invariants and gotchas

- Read paths degrade, the send path never does. Every read adapter
  wraps the live call in `condition-case` and falls back to fixtures;
  `lark-org--live-send` signals on any failure so a draft keeps its
  `:draft:` tag. Do not add silent fallbacks to write paths.
- `:json-false` is truthy in Elisp. `lark-org--truthy` guards this;
  the code and tests call it out as a previously fixed bug. Any new
  JSON boolean check must go through it.
- The send content is double-encoded. `lark-org--encode-text-content`
  wraps text as a JSON string that itself goes into the JSON body;
  test.el pins the exact wire shape. Getting this wrong 400s the send.
- The chat id never appears in buffer text. It rides as a text
  property (`lark-org-chat-id`) on the heading line; the preview line
  belongs to the heading above it (`lark-org--chat-id-here` looks one
  line up). Motion or copy code that strips properties loses it.
- Tags are parsed by the package's own regexp
  (`lark-org--view-tags-re`), not Org's element cache, because the
  view owns the heading grammar. Changes to heading text must keep
  that regexp in sync.
- Only one draft per view. `lark-org-view-compose` replaces an
  existing `:draft:` entry in place (new text wins) instead of
  appending a second one. A failed immediate send re-inserts the
  draft so the composed text is never lost.
- View buffers are rebuilt, not updated. `lark-org-view-render`
  renames the old buffer to ` *Lark Org-old*`, builds a fresh one,
  repoints the windows, then kills the old buffer; this resets Org
  fold state deliberately. `lark-org--view-chat-id` and
  `lark-org--view-unread-p` are permanent-local so they survive.
- Opening a chat is reading it. The marker is stamped before the
  buffer is drawn, so a list refresh right after opening shows zero
  unread for that chat. This is intended.
- History authors are bare sender ids (the API exposes no member
  names); "me" only appears when the sender id equals
  `lark-org-self-open-id`. Mentions are always 0 (the endpoint has
  no mention model); the package refuses to guess one.
- Secrets stay in memory. The app secret comes from auth-source
  (`machine lark-org login app-secret password <secret>`), the token
  and secret are never inserted into buffers or logged, and the token
  cache is two defvars, nothing else.
- Unread cost. With `lark-org-markers` non-nil, every list refresh
  costs one bounded history read per chat. On a big chat list this is
  the slow path; setting `lark-org-markers` nil restores the v0.1
  zero-cost placeholders (0 tags, "..." preview).
- Buffers are read-only with undo disabled; all package writes go
  through `inhibit-read-only` locally. Respect that in new verbs.
- `q` buries, never kills (section 8 of the standard).

## Developing

Commands (from the Makefile; EMACS overrides the binary, default
`emacs`):

    make compile   # byte-compile with warnings as errors
    make test      # ERT suite: emacs --batch -L . -l test -f ert-run-tests-batch-and-exit
    make clean     # remove .elc files

There is no CI workflow file in this repo; the Makefile targets are
the canonical check. The test suite stubs the transport seam and
leaves `lark-org-app-id` unset so any accidental live call fails fast;
keep it that way when adding tests (36 tests currently cover the
converters, grammar, markers, drafts, sends, and verbs).

Requires Emacs 28.1+.

Branch law: `ai/main` is the integration trunk; work lands there.
Conventions to preserve: the ORG-CHAT-STANDARD v1.1 grammar (list =
sections 3, view = section 4, verbs = section 7, buffer law =
section 8), package prefix `lark-org-`, and the disclosed-limits
register in README.org (update it when a limit changes).
