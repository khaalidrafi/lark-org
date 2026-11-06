;;; lark-org-tests.el --- Tests for lark-org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 lark-org authors

;; Author: lark-org authors
;; Package-Requires: ((emacs "28.1"))
;; Keywords: comm, org
;; Version: 0.1

;;; Commentary:

;; Deterministic ERT tests for the lark-org grammar and converters.
;; No network: the transport seam is stubbed; app-id is left unset so
;; any accidental live call fails fast instead of reaching out.

;;; Code:

(require 'ert)
(require 'org)
(require 'lark-org)

(defun lark-org-tests--render-list ()
  "Render the fixture index and return the list buffer."
  (let ((lark-org-index-function #'lark-org--fixture-index))
    (lark-org-render)))

(defun lark-org-tests--render-view ()
  "Render the fixture conversation and return the view buffer."
  (let ((lark-org-view-fetch-function #'lark-org--fixture-view))
    (lark-org-view-render "oc_fixture_hq")))

(defun lark-org-tests--line-at-point ()
  "Return the current line's text without properties."
  (buffer-substring-no-properties
   (line-beginning-position) (line-end-position)))

;;;; Transport, envelope, truthiness

(ert-deftest lark-org-tests-truthy ()
  "JSON false must never count as truth (the documented elisp trap)."
  (should (null (lark-org--truthy :json-false)))
  (should (eq (lark-org--truthy t) t))
  (should (equal (lark-org--truthy "x") "x"))
  (should (= (lark-org--truthy 0) 0)))

(ert-deftest lark-org-tests-envelope ()
  "A non-zero API code signals `lark-org-api-error' with the msg."
  (lark-org--check-envelope (list '(code . 0) '(msg . "ok")))
  (should (condition-case err
              (progn (lark-org--check-envelope
                      (list '(code . 230001) '(msg . "forbidden")))
                     nil)
            (lark-org-api-error
             (string-match-p "230001" (cadr err))))))

(ert-deftest lark-org-tests-encode-text-content ()
  "The im/v1 send API double-encodes content; pin the exact shape."
  (should (string= (lark-org--encode-text-content "hi")
                   "{\"text\":\"hi\"}"))
  (should (string= (lark-org--encode-text-content "a\"b\\c")
                   "{\"text\":\"a\\\"b\\\\c\"}"))
  (should (string=
           (json-encode (list (cons "receive_id" "oc_1")
                              (cons "msg_type" "text")
                              (cons "content"
                                    (lark-org--encode-text-content
                                     "hi"))))
           "{\"receive_id\":\"oc_1\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":\\\"hi\\\"}\"}")))

(ert-deftest lark-org-tests-query-string ()
  "Query keys and values are hexified."
  (should (string= (lark-org--query-string nil) ""))
  (should (string= (lark-org--query-string
                    (list (cons "container_id" "oc a b")))
                   "?container_id=oc%20a%20b")))

;;;; Converters

(ert-deftest lark-org-tests-decode-content-text ()
  "Text content decodes; JSON-string envelope handled."
  (should (string= (lark-org--decode-content
                    "text" "{\"text\":\"hey there\"}")
                   "hey there"))
  (should (string= (lark-org--decode-content "text" "{\"text\":\"\"}")
                   "")))

(ert-deftest lark-org-tests-decode-content-kinds ()
  "Textless message types degrade to kind words (section 3 rule 4)."
  (should (string= (lark-org--decode-content "image" "{}") "photo"))
  (should (string= (lark-org--decode-content "audio" "{}") "voice"))
  (should (string= (lark-org--decode-content "media" "{}") "video"))
  (should (string= (lark-org--decode-content "file" "{}") "file"))
  (should (string= (lark-org--decode-content "sticker" "{}") "sticker"))
  (should (string= (lark-org--decode-content "interactive" "{}")
                   "card")))

(ert-deftest lark-org-tests-decode-content-post ()
  "Post content: title, runs joined, links and mentions degrade to
plain text with Org links for hrefs (section 4 rule 3)."
  (let ((raw "{\"title\":\"Title\",\"content\":[[{\"tag\":\"text\",\"text\":\"para one \"},{\"tag\":\"a\",\"text\":\"link\",\"href\":\"https://x.example\"}],[{\"tag\":\"at\",\"user_name\":\"bob\"}]]}"))
    (should (string= (lark-org--decode-content "post" raw)
                     "Title\npara one [[https://x.example][link]]\n@bob"))))

(ert-deftest lark-org-tests-message-from-item ()
  "History items convert: ms-string time, self detection, drawers."
  (let* ((ms (number-to-string
              (* 1000 (round
                       (float-time
                        (encode-time 0 0 0 1 1 2026 t))))))
         (item (list '(message_id . "om_9")
                     '(msg_type . "text")
                     (cons 'create_time ms)
                     (cons 'sender (list (cons 'id "ou_self")
                                         '(id_type . "open_id")))
                     (cons 'body (list (cons 'content
                                             "{\"text\":\"hi from self\"}")))))
         (msg (let ((lark-org-self-open-id "ou_self"))
                (lark-org--message-from-item item))))
    (should (string= (plist-get msg :id) "om_9"))
    (should (= (float-time (plist-get msg :time))
               (float-time (encode-time 0 0 0 1 1 2026 t))))
    (should (string= (plist-get msg :author) "me"))
    (should (plist-get msg :out))
    (should (string= (plist-get msg :text) "hi from self")))
  (let* ((item (list '(message_id . "om_10")
                     '(msg_type . "text")
                     (cons 'sender (list (cons 'id "ou_khalid")))
                     (cons 'body (list (cons 'content
                                             "{\"text\":\"hi\"}")))))
         (msg (lark-org--message-from-item item)))
    (should (string= (plist-get msg :author) "ou_khalid"))
    (should (null (plist-get msg :out)))))

(ert-deftest lark-org-tests-index-from-items ()
  "Group membership is data: first match wins, fallback otherwise
(section 3 rule 1); the list carries no unread model (disclosed)."
  (let ((lark-org-group-alist
         '(("\\`hq\\'" . "Teams") ("." . "Everything")))
        (items (list (list '(chat_id . "oc_1") '(name . "hq"))
                     (list '(chat_id . "oc_2") '(name . "Alice"))
                     (list '(chat_id . "oc_3") '(name . "bots")))))
    (let ((plists (lark-org--index-from-items items)))
      (should (string= (plist-get (nth 0 plists) :group) "Teams"))
      (should (string= (plist-get (nth 1 plists) :group) "Everything"))
      (should (string= (plist-get (nth 2 plists) :group)
                       "Everything"))
      (dolist (p plists)
        (should (= (plist-get p :unread) 0))
        (should (= (plist-get p :mentions) 0)))))
  (let ((lark-org-group-alist nil)
        (lark-org-fallback-group "Chats"))
    (should (string= (lark-org--group-for "anything") "Chats"))))

(ert-deftest lark-org-tests-kind-of ()
  "Lark chat_type maps into the section 4 kind vocabulary."
  (should (string= (lark-org--kind-of "p2p") "im"))
  (should (string= (lark-org--kind-of "group") "group"))
  (should (string= (lark-org--kind-of "") "im")))

;;;; Auth cache and bounded retry (transport stubbed, no network)

(defvar lark-org-tests--http-calls)

(defun lark-org-tests--stub-http ()
  "Install a counting transport stub; return the call counter symbol."
  (setq lark-org-tests--http-calls 0)
  (lambda (method url headers body)
    (setq lark-org-tests--http-calls
          (1+ lark-org-tests--http-calls))
    (ignore method headers body)
    (cond ((string-suffix-p "tenant_access_token/internal" url)
           "{\"code\":0,\"tenant_access_token\":\"t-fixture-never-real\",\"expire\":7200}")
          ((string-match-p "/im/v1/chats" url)
           (if (< lark-org-tests--http-calls 3)
               ;; First chats call (after the first token) fails with
               ;; a token error; the retry after the fresh token wins.
               "{\"code\":99991663,\"msg\":\"invalid token\"}"
             "{\"code\":0,\"data\":{\"items\":[{\"chat_id\":\"oc_1\",\"name\":\"hq\"}]}}"))
          (t "{\"code\":0,\"data\":{}}"))))

(ert-deftest lark-org-tests-token-cache-and-retry ()
  "Token cached across calls; a token-error code refreshes once and
retries (bounded); secrets never enter the rendered buffer."
  (cl-letf* (((symbol-function 'lark-org--app-secret)
              (lambda () "fixture-secret-never-real"))
             (stub (lark-org-tests--stub-http))
             (lark-org-app-id "cli_fixture")
             (lark-org-http-function (lambda (m u h b)
                                       (funcall stub m u h b)))
             (lark-org-index-function #'lark-org--live-index)
             (lark-org--token nil)
             (lark-org--token-expiry 0)
             (buf (lark-org-render)))
    ;; Calls: token + chats(fail) + token(refresh) + chats(ok) = 4.
    (should (>= lark-org-tests--http-calls 4))
    (with-current-buffer buf
      (goto-char (point-min))
      (should (string-match-p "\\*\\* hq" (buffer-string)))
      ;; Section 9.10: no token or secret value enters the buffer.
      (should (not (string-match-p "t-fixture-never-real"
                                   (buffer-string))))
      (should (not (string-match-p "fixture-secret-never-real"
                                   (buffer-string)))))))

(ert-deftest lark-org-tests-live-send-requires-app-id ()
  "A write path without configuration signals; it never fakes ok."
  (let ((lark-org-app-id ""))
    (should-error (lark-org--live-send "oc_1" "hi") :type 'user-error)))

;;;; List grammar (section 3)

(ert-deftest lark-org-tests-list-buffer ()
  "The list buffer is \"*Lark Org*\": org-mode, read-only, no undo,
reused across renders."
  (let ((buf (lark-org-tests--render-list)))
    (should (string= (buffer-name buf) "*Lark Org*"))
    (with-current-buffer buf
      (should buffer-read-only)
      (should (eq major-mode 'org-mode))
      (should (eq buffer-undo-list t)))
    (should (eq (lark-org-tests--render-list) buf))))

(ert-deftest lark-org-tests-list-grammar ()
  "Level-1 groups, level-2 chats, exactly two lines per chat, tag
pairs rendered with the numeric partner (section 3 + section 5)."
  (with-current-buffer (lark-org-tests--render-list)
    (goto-char (point-min))
    (should (= (org-current-level) 1))
    (should (string= (org-get-heading t t t t) "Pinned"))
    (org-next-visible-heading 1)
    (should (= (org-current-level) 2))
    (should (string= (lark-org-tests--line-at-point)
                     "** Alice :unread:3:"))
    (forward-line 1)
    (should (string= (lark-org-tests--line-at-point)
                     "  2m  ↓ call me tonight"))
    (forward-line 1)
    (should (string= (lark-org-tests--line-at-point) "* Teams"))
    (forward-line 1)
    (should (string= (lark-org-tests--line-at-point)
                     "** hq :mention:2:"))
    (forward-line 1)
    (should (string= (lark-org-tests--line-at-point)
                     "  5m  ↑ on it -- standard first"))))

;;;; View grammar (section 4)

(ert-deftest lark-org-tests-view-buffer ()
  "The view buffer is \"*Lark Org: hq*\": org-mode, read-only, no
undo, STARTUP overview, CHAT-ID/KIND drawer."
  (let ((buf (lark-org-tests--render-view)))
    (should (string= (buffer-name buf) "*Lark Org: hq*"))
    (with-current-buffer buf
      (should buffer-read-only)
      (should (eq major-mode 'org-mode))
      (should (eq buffer-undo-list t))
      (goto-char (point-min))
      (should (looking-at "#\\+STARTUP: overview"))
      (should (string-match-p ":CHAT-ID:  oc_fixture_hq"
                              (buffer-string)))
      (should (string-match-p ":KIND:     group" (buffer-string)))
      (should (string= lark-org--view-chat-id "oc_fixture_hq")))))

(ert-deftest lark-org-tests-view-message-grammar ()
  "Per-message headings: inactive stamp, author, tags, drawers;
URLs become Org links; drawer-lookalike text degrades; only the
FIRST unread message carries the marker (rules 2-3, 5, 7)."
  (with-current-buffer (lark-org-tests--render-view)
    (let ((text (buffer-string)))
      (should (string-match-p
               "\\*\\* \\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [A-Za-z]\\{3\\} [0-9]\\{2\\}:[0-9]\\{2\\}\\] kh\\. :unread:2:"
               text))
      (should (string-match-p "\\*\\* .+ me :out:" text))
      (should (string-match-p ":MSG-ID:  om_1" text))
      (should (string-match-p ":AUTHOR:  ou_khalid" text))
      (should (string-match-p ":AUTHOR:  ou_self" text))
      (should (string-match-p "\\[\\[https://example.org/brief\\]\\]"
                              text))
      (should (string-match-p ": END: look-alike line" text))
      ;; om_3's unread was suppressed in the render (first-only law):
      ;; exactly one unread tag chunk in the view.
      (should (= (how-many ":unread:" (point-min) (point-max)) 1)))))

(ert-deftest lark-org-tests-unread-clears-past-marker ()
  "Moving point past the first unread removes the marker with its
numeric partner and keeps the other tags (section 4 rule 7)."
  (with-current-buffer (lark-org-tests--render-view)
    (let ((pos (lark-org--view-unread-position)))
      (should pos)
      (goto-char pos)
      (forward-line 1)
      (lark-org--view-unread-watch)
      (should (null lark-org--view-unread-p))
      (should (null (lark-org--view-unread-position)))
      (should (string-match-p ":out:" (buffer-string))))))

(ert-deftest lark-org-tests-jump-unread ()
  "j jumps to the first unread message heading."
  (with-current-buffer (lark-org-tests--render-view)
    (lark-org-jump-unread)
    (should (member "unread" (lark-org--view-entry-tags)))))

;;;; Drafts and sends (section 4 rule 8)

(ert-deftest lark-org-tests-compose-single-draft ()
  "A view holds at most one :draft:; recomposing replaces it in
place and point lands on the draft heading."
  (with-current-buffer (lark-org-tests--render-view)
    (lark-org-view-compose "draft one")
    (goto-char (point-min))
    (lark-org-view-compose "draft two")
    (let ((text (buffer-string)))
      (should (= (how-many ":draft:" (point-min) (point-max)) 1))
      (should (string-match-p "draft two" text))
      (should (not (string-match-p "draft one" text))))
    (should (member "draft" (lark-org--view-entry-tags)))))

(ert-deftest lark-org-tests-send-draft ()
  "C-c C-c: send, retag :out:, stamp :MSG-ID:; the send seam gets
the view's chat id and the draft body."
  (let* ((sent nil)
         (lark-org-send-function
          (lambda (chat-id text)
            (setq sent (list chat-id text))
            "om_sent_9")))
    (with-current-buffer (lark-org-tests--render-view)
      (lark-org-view-compose "ship it")
      ;; send-draft sends the :draft: entry at point (rule 8).
      (goto-char (lark-org--first-tagged-position "draft"))
      (lark-org-view-send-draft)
      (should (equal sent (list "oc_fixture_hq" "ship it")))
      (let ((text (buffer-string)))
        (should (= (how-many ":draft:" (point-min) (point-max)) 0))
        (should (string-match-p "\\*\\* .+ me :out:" text))
        (should (string-match-p ":MSG-ID:  om_sent_9" text))))))

(ert-deftest lark-org-tests-failed-send-keeps-draft ()
  "A send that signals leaves the draft :draft: and unedited
(a write path never pretends to succeed)."
  (let ((lark-org-send-function
         (lambda (_chat-id _text) (error "lark-org: send failed"))))
    (with-current-buffer (lark-org-tests--render-view)
      (lark-org-view-compose "not yet")
      (should-error (lark-org-view-send-draft))
      (should (= (how-many ":draft:" (point-min) (point-max)) 1))
      (should (string-match-p "not yet" (buffer-string))))))

(ert-deftest lark-org-tests-send-id-may-be-absent ()
  "A backend returning no id leaves the drawer without :MSG-ID:
(never stamp a placeholder into the machine-read drawer)."
  (let ((lark-org-send-function (lambda (_chat-id _text) "")))
    (with-current-buffer (lark-org-tests--render-view)
      (lark-org-view-compose "no id")
      (goto-char (lark-org--first-tagged-position "draft"))
      (lark-org-view-send-draft)
      (let ((text (buffer-string)))
        (should (= (how-many ":draft:" (point-min) (point-max)) 0))
        (should (string-match-p ":out:" text))
        (should (not (string-match-p ":MSG-ID:  -" text)))))))

;;;; Verbs (section 7)

(ert-deftest lark-org-tests-verb-keymaps ()
  "The verb keymaps carry the section 7 grammar; the shared maps
are never mutated by touch mode."
  (should (eq (lookup-key lark-org-list-mode-map "g")
              #'lark-org-refresh))
  (should (eq (lookup-key lark-org-list-mode-map (kbd "RET"))
              #'lark-org-open-at-point))
  (should (eq (lookup-key lark-org-list-mode-map "n")
              #'lark-org-next-chat))
  (should (eq (lookup-key lark-org-list-mode-map "p")
              #'lark-org-previous-chat))
  (should (eq (lookup-key lark-org-view-mode-map "\C-c\C-c")
              #'lark-org-view-send-draft))
  (should (eq (lookup-key lark-org-view-mode-map "j")
              #'lark-org-jump-unread))
  (should (eq (lookup-key lark-org-touch-mode-map [down-mouse-1])
              #'lark-org--tap-mouse)))

(ert-deftest lark-org-tests-quit-buries ()
  "q buries the buffer (section 8): the buffer survives."
  (with-current-buffer (lark-org-tests--render-list)
    (lark-org-quit)
    (should (buffer-live-p (get-buffer "*Lark Org*")))))

(ert-deftest lark-org-tests-refresh-delegates ()
  "g in a view refreshes the surface it was invoked on; the fresh
buffer is adopted (kill-rebuild law)."
  (with-current-buffer (lark-org-tests--render-view)
    (lark-org-view-refresh)
    (should (derived-mode-p 'org-mode))
    (should (string= lark-org--view-chat-id "oc_fixture_hq"))))

;;;; Touch adaptation (section 7)

(ert-deftest lark-org-tests-tap-verbs ()
  "Tap on a chat opens it, tap on a heading cycles, elsewhere is
an error -- no hover-dependent feature."
  (with-current-buffer (lark-org-tests--render-list)
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should (string= (lark-org--chat-id-here) "oc_fixture_alice"))
    (let ((buf (lark-org-view-render "oc_fixture_alice")))
      ;; The fixture conversation is deterministic: whatever the chat
      ;; id asked for, the fixture renders its own hq transcript.
      (should (string= (buffer-name buf) "*Lark Org: hq*")))))

;;;; Read markers (the v0.2 local unread model)

;; The marker registry is kept in memory for every test in this
;; section (load-once satisfied), and the state file lands in a temp
;; directory, so the developer's real markers are never touched.

(defun lark-org-tests--history-item (id ms-ago text &optional out)
  "Return one raw history item the way the live API spells it.
MS-AGO is truncated to whole milliseconds; keys are symbols, the
shape `lark-org--decode-json' hands over (object-type alist)."
  (list (cons 'message_id id)
        (cons 'create_time (number-to-string (truncate ms-ago)))
        (cons 'msg_type "text")
        (cons 'sender (list (cons 'id
                                  (if out "ou_self" "ou_khalid"))))
        (cons 'body (list (cons 'content
                                (json-encode
                                 (list (cons "text" text))))))))

(defmacro lark-org-tests--with-markers (&rest body)
  "Run BODY with a clean in-memory marker registry and a temp file.
The state file lives inside a fresh temp directory, so the
developer's real markers are never touched."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "lark-org-tests" t))
          (lark-org--read-state nil)
          (lark-org--read-state-loaded t)
          (lark-org-read-state-file
           (expand-file-name "state" dir)))
     (unwind-protect
         (progn ,@body)
       (delete-directory dir t))))

(ert-deftest lark-org-tests-unread-count ()
  "Unread = messages strictly newer than the marker; undated never."
  (let ((msgs (list (list :id "a" :time (seconds-to-time 100))
                    (list :id "b" :time (seconds-to-time 200))
                    (list :id "c" :time nil)
                    (list :id "d" :time (seconds-to-time 300)))))
    (should (= (lark-org--unread-count msgs 0) 3))
    (should (= (lark-org--unread-count msgs 100) 2))
    (should (= (lark-org--unread-count msgs 300) 0))
    (should (= (lark-org--unread-count msgs 999) 0))))

(ert-deftest lark-org-tests-read-state-roundtrip ()
  "Markers persist to `lark-org-read-state-file' and read back."
  (lark-org-tests--with-markers
    (lark-org--stamp-read "oc_x" (seconds-to-time 500))
    (should (= (cdr (assoc "oc_x" lark-org--read-state)) 500.0))
    ;; a stamp that moves backwards is a no-op: a stale view cannot
    ;; un-read what a fresh one saw
    (lark-org--stamp-read "oc_x" (seconds-to-time 100))
    (should (= (cdr (assoc "oc_x" lark-org--read-state)) 500.0))
    ;; a fresh session reads the same markers back
    (setq lark-org--read-state nil lark-org--read-state-loaded nil)
    (lark-org--read-state-ensure)
    (should (= (cdr (assoc "oc_x" lark-org--read-state)) 500.0))))

(ert-deftest lark-org-tests-read-state-corrupt-file ()
  "A corrupt state file reads as no markers, never an error."
  (lark-org-tests--with-markers
    (write-region "((broken" nil lark-org-read-state-file)
    (setq lark-org--read-state-loaded nil)
    (lark-org--read-state-ensure)
    (should (null lark-org--read-state))))

(ert-deftest lark-org-tests-enrich-preview-and-unread ()
  "The list heading renders a real unread tag and real preview
from bounded history through the seam; first sight baselines."
  (lark-org-tests--with-markers
    (let* ((now (float-time))
           (history
            (list (lark-org-tests--history-item
                   "om_a" (* 1000 (- now 300)) "first in")
                  (lark-org-tests--history-item
                   "om_b" (* 1000 (- now 200)) "call me tonight")))
           (calls nil)
           (lark-org-history-function
            (lambda (chat-id)
              (push chat-id calls) history))
           (chats (lark-org--enrich-chat
                   (list :id "oc_alice" :group "Pinned" :name "Alice"
                         :unread 0 :mentions 0 :muted nil
                         :last-time "" :last-dir 'in :last-text "..."))))
      ;; first sight: baseline stamped at the newest message, zero tags
      ;; (the API stamps whole milliseconds, so hold the second-wide
      ;; slack the create_time -> seconds truncation costs)
      (should (= (plist-get chats :unread) 0))
      (should (equal calls '("oc_alice")))
      (should (< (abs (- (cdr (assoc "oc_alice" lark-org--read-state))
                         (- now 200)))
                 1.5))
      (should (string= (plist-get chats :last-text) "call me tonight"))
      (should (eq (plist-get chats :last-dir) 'in))
      ;; now two messages arrive, the newest outgoing; the count
      ;; measures against the marker
      (let ((lark-org-self-open-id "ou_self"))
        (setq history
              (append history
                      (list (lark-org-tests--history-item
                             "om_c" (* 1000 (- now 100)) "one more")
                            (lark-org-tests--history-item
                             "om_d" (* 1000 (- now 50)) "and me" t))))
        (setq chats (lark-org--enrich-chat
                     (list :id "oc_alice" :group "Pinned" :name "Alice"
                           :unread 0 :mentions 0 :muted nil
                           :last-time "" :last-dir 'in :last-text "...")))
        (should (= (plist-get chats :unread) 2))
        (should (eq (plist-get chats :last-dir) 'out)))
      ;; a failing history read degrades to the v0.1 placeholders
      (let ((lark-org-history-function
             (lambda (_) (error "api down"))))
        (setq chats (lark-org--enrich-chat
                     (list :id "oc_alice" :group "Pinned" :name "Alice"
                           :unread 0 :mentions 0 :muted nil
                           :last-time "" :last-dir 'in :last-text "...")))
        (should (string= (plist-get chats :last-text) "..."))
        (should (= (plist-get chats :unread) 0))))))

(ert-deftest lark-org-tests-markers-nil-keeps-placeholders ()
  "With `lark-org-markers' nil nothing feeds off history or markers:
the converters keep the v0.1 placeholder values untouched."
  (let ((lark-org-markers nil)
        (lark-org-history-function
         (lambda (_) (error "history must not be read"))))
    ;; the index converter alone speaks placeholders
    (let ((chats (lark-org--index-from-items
                  (list (list (cons 'chat_id "oc_a")
                              (cons 'name "Alice"))))))
      (should (= (plist-get (car chats) :unread) 0))
      (should (string= (plist-get (car chats) :last-text) "...")))
    ;; the view converter leaves every unread flag unset
    (let ((conv (lark-org--view-from-items "oc_a" "Alice" "im"
                                           (list
                                            (lark-org-tests--history-item
                                             "om_a" 1000 "hi")))))
      (should (cl-every #'null
                        (mapcar (lambda (m) (plist-get m :unread))
                                (plist-get conv :messages)))))))

(ert-deftest lark-org-tests-view-open-stamps-read ()
  "Rendering a view stamps the chat's marker past its newest message."
  (lark-org-tests--with-markers
    (let ((newest (car (last (plist-get
                              (lark-org--fixture-view "oc_fixture_hq")
                              :messages)))))
      (lark-org-view-render "oc_fixture_hq")
      (should (= (cdr (assoc "oc_fixture_hq" lark-org--read-state))
                 (float-time (plist-get newest :time)))))))

(ert-deftest lark-org-tests-apply-unread-flags ()
  "First unread message carries the count, the rest t, rest nil."
  (lark-org-tests--with-markers
    (let* ((now (float-time))
           (msgs (list (list :id "m1" :time (seconds-to-time
                                             (- now 300)) :unread nil)
                       (list :id "m2" :time (seconds-to-time
                                             (- now 20)) :unread nil)
                       (list :id "m3" :time (seconds-to-time
                                             (- now 10)) :unread nil)
                       (list :id "m4" :time (seconds-to-time
                                             (- now 5)) :unread nil))))
      ;; no marker yet: no flags (the baseline lands at view render)
      (should (cl-every #'null
                        (mapcar (lambda (m) (plist-get m :unread))
                                (lark-org--apply-unread "oc_hq" msgs))))
      ;; marker at now-30: three unread, first carries the count
      (setq lark-org--read-state (list (cons "oc_hq" (- now 30))))
      (let ((flagged (lark-org--apply-unread "oc_hq" msgs)))
        (should (null (plist-get (nth 0 flagged) :unread)))
        (should (equal (plist-get (nth 1 flagged) :unread) 3))
        (should (eq (plist-get (nth 2 flagged) :unread) t))
        (should (eq (plist-get (nth 3 flagged) :unread) t))))))

(ert-deftest lark-org-tests-relative-time ()
  "Preview stamps speak the fixture vocabulary: now/m/h/d, then date."
  (let ((now (float-time)))
    (should (string= (lark-org--relative-time (seconds-to-time
                                               (- now 5)))
                     "now"))
    (should (string= (lark-org--relative-time (seconds-to-time
                                               (- now 120)))
                     "2m"))
    (should (string= (lark-org--relative-time (seconds-to-time
                                               (- now 7200)))
                     "2h"))
    (should (string= (lark-org--relative-time (seconds-to-time
                                               (- now 172800)))
                     "2d"))
    (should (string-match-p
             "^[0-9][0-9]\\.[0-9][0-9]\\.[0-9][0-9]$"
             (lark-org--relative-time (seconds-to-time
                                       (- now 1209600)))))))

(provide 'lark-org-tests)
;;; lark-org-tests.el ends here
