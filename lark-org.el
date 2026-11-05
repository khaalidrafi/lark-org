;;; lark-org.el --- Org chat UI for Lark Messenger -*- lexical-binding: t; -*-

;; Copyright (C) 2026 lark-org authors

;; Author: lark-org authors
;; Package-Requires: ((emacs "28.1"))
;; Keywords: comm, org
;; Version: 0.1

;;; Commentary:

;; Render Lark Messenger chats as Org buffers, per ORG-CHAT-STANDARD
;; v1.1 (sections 2-8):
;;
;;   * Lark Org                 the chat list (section 3 grammar)
;;   * Lark Org: <chat>         one conversation (section 4 grammar)
;;
;; The backend is the Lark Open Platform REST API (Lark international
;; defaults to https://open.larksuite.com; set `lark-org-api-base' to
;; https://open.feishu.cn for Feishu).  Endpoints used:
;;
;;   POST /open-apis/auth/v3/tenant_access_token/internal
;;   GET  /open-apis/im/v1/chats
;;   GET  /open-apis/im/v1/messages?container_id_type=chat&...
;;   POST /open-apis/im/v1/messages?receive_id_type=chat_id
;;
;; Setup: create a Lark app with im:message scopes, set
;; `lark-org-app-id', and store the app secret in auth-source:
;;
;;     machine lark-org login app-secret password <secret>
;;
;; (`lark-org-secret-auth-source' selects the host/user pair.)  The
;; secret and the cached tenant token live in memory only; neither
;; ever enters a buffer, message, or log (standard section 9.10).
;;
;; Design law:
;; - Add-on, one .el, no backend in Package-Requires (section 1); the
;;   transport is built-in url.el behind `lark-org-http-function'.
;; - Read adapters degrade to deterministic fixtures when the API is
;;   unreachable or unconfigured, so offline behavior and the ERT
;;   suites stay stable; the send adapter is the one deliberate
;;   exception -- a write path never pretends to succeed (section 4
;;   rule 8).
;; - Group membership is user data (`lark-org-group-alist', first
;;   match wins, fallback group), never hard-coded (section 3 rule 1).
;; - Outgoing detection: a message whose sender id equals
;;   `lark-org-self-open-id' is yours.
;;
;; Disclosed limits (v0.1, logged in CANDIDATES.org):
;; - The chats endpoint carries no unread/mention model and no last
;;   message preview, so list tags are 0 and previews render the
;;   honest placeholder "..." until the read-marker unit lands.
;; - History authors are sender ids (the history endpoint exposes no
;;   member names); the view shows the id, "unknown" when empty.
;; - History is bounded to `lark-org-max-pages' pages.

;;; Code:

(require 'org)
(require 'json)
(require 'url)
(require 'auth-source)
(require 'cl-lib)

(defvar search-invisible)
(defvar url-http-response-status)

(define-error 'lark-org-api-error "lark-org API error")

;;;; Faces (standard section 6, package prefix)

(defface lark-org-unread-face
  '((t (:weight bold)))
  "Unread tag face (standard section 6)."
  :group 'lark-org)

(defface lark-org-mention-face
  '((t (:weight bold :foreground "firebrick")))
  "Mention tag face (standard section 6)."
  :group 'lark-org)

(defface lark-org-preview-face
  '((t (:foreground "gray45")))
  "Preview line face (standard section 6)."
  :group 'lark-org)

(defface lark-org-time-face
  '((t (:foreground "gray40")))
  "Time face (standard section 6)."
  :group 'lark-org)

(defface lark-org-current-face
  '((t (:weight bold :underline t)))
  "Current chat face (standard section 6)."
  :group 'lark-org)

;;;; Configuration

(defgroup lark-org nil
  "Org chat UI for Lark Messenger."
  :group 'comm
  :prefix "lark-org-")

(defcustom lark-org-api-base "https://open.larksuite.com"
  "Lark Open Platform base URL.
Use \"https://open.feishu.cn\" for Feishu (China)."
  :type 'string
  :group 'lark-org)

(defcustom lark-org-app-id ""
  "Lark app id (cli_...).  The app secret is NOT set here: it is
read from auth-source per `lark-org-secret-auth-source'."
  :type 'string
  :group 'lark-org)

(defcustom lark-org-secret-auth-source '(:host "lark-org" :user "app-secret")
  "auth-source host/user pair holding the Lark app secret."
  :type 'plist
  :group 'lark-org)

(defcustom lark-org-self-open-id ""
  "Your sender id (open_id); matching messages render author \"me\"
and carry the :out: tag.  Empty means no message is counted as
outgoing (drafts still are)."
  :type 'string
  :group 'lark-org)

(defcustom lark-org-group-alist nil
  "Group membership as data (standard section 3 rule 1).
An alist of (REGEXP . GROUP-NAME); the first matching regexp wins,
a chat matching nothing goes to `lark-org-fallback-group'."
  :type '(repeat (cons regexp string))
  :group 'lark-org)

(defcustom lark-org-fallback-group "Chats"
  "Group name for chats that match nothing in
`lark-org-group-alist'."
  :type 'string
  :group 'lark-org)

(defcustom lark-org-page-size 50
  "Items per page for the chats and history endpoints."
  :type 'integer
  :group 'lark-org)

(defcustom lark-org-max-pages 3
  "Maximum pages fetched per read (bounded pagination)."
  :type 'integer
  :group 'lark-org)

(defcustom lark-org-http-timeout 15
  "Seconds per HTTP request."
  :type 'integer
  :group 'lark-org)

(defcustom lark-org-http-function #'lark-org--http-url
  "Transport seam: function of (METHOD URL HEADERS BODY).
HEADERS is an alist of strings; BODY is a JSON string or nil.
Returns the response body as a string, signaling on transport
failure.  Bind a stub for offline tests (standard section 9.9)."
  :type 'function
  :group 'lark-org)

(defcustom lark-org-index-function #'lark-org--live-index
  "Function returning the chat index as a list of plists with keys
:id :group :name :unread :mentions :muted :last-time :last-dir
:last-text.  The default asks the Lark API and degrades to the
deterministic fixture when the API is unreachable or
unconfigured, so offline behavior and tests stay stable."
  :type 'function
  :group 'lark-org)

(defcustom lark-org-view-fetch-function #'lark-org--live-view
  "Function of one argument, a chat id, returning a conversation
plist with keys :id :name :kind :messages (:kind one of \"im\",
\"group\", \"channel\"; messages plists with keys :id :time :author
:handle :text :out :unread :mention).  The default asks the Lark
API and degrades to the deterministic fixture on failure."
  :type 'function
  :group 'lark-org)

(defcustom lark-org-send-function #'lark-org--live-send
  "Function of two arguments, CHAT-ID and TEXT, sending a message.
Returns the backend-assigned message id (nil when the API returns
none -- the drawer then stays without :MSG-ID:, standard section
5); signals on failure so the draft keeps :draft:.  A write path
never degrades silently."
  :type 'function
  :group 'lark-org)

(defcustom lark-org-adapt-for-touch t
  "Non-nil to adapt the buffers to touch screens: a single tap
acts like RET on a chat (section 7 touch law); no feature depends
on hover."
  :type 'boolean
  :group 'lark-org)

(defvar lark-org-current-chat-id nil
  "Id of the chat currently open, or nil.  The matching list
heading gets `lark-org-current-face'.")
(make-variable-buffer-local 'lark-org-current-chat-id)

;;;; JSON and transport

(defun lark-org--truthy (v)
  "Return V unless it is :json-false (which is TRUTHY in elisp --
the trap this crew already fixed once; keep the guard)."
  (and (not (eq v :json-false)) v))

(defun lark-org--s (v)
  "Return V as a property-stripped string, or \"\"."
  (substring-no-properties
   (cond ((stringp v) v)
         ((numberp v) (number-to-string v))
         (t ""))))

(defun lark-org--decode-json (s)
  "Decode the JSON string S to an alist tree."
  (unless (and (stringp s) (not (string-empty-p s)))
    (error "lark-org: empty API response"))
  (json-parse-string s :object-type 'alist :array-type 'list
                     :false-object :json-false :null-object nil))

(defun lark-org--check-envelope (obj)
  "Signal `lark-org-api-error' when OBJ carries a non-zero code."
  (let ((code (alist-get 'code obj)))
    (when (and (numberp code) (not (zerop code)))
      (signal 'lark-org-api-error
              (list (format "code %s: %s"
                            code (lark-org--s (alist-get 'msg obj))))))))

(defun lark-org--http-url (method url headers body)
  "Default transport over `url-retrieve-synchronously'."
  (let ((url-request-method method)
        (url-request-extra-headers headers)
        (url-request-data body))
    (let ((buf (url-retrieve-synchronously
                url nil nil lark-org-http-timeout)))
      (unless buf
        (error "lark-org: request failed: %s %s" method url))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (if (looking-at-p "HTTP/1\\.[01] [23]")
                (progn
                  (re-search-forward "\r?\n\r?\n" nil t)
                  (buffer-substring-no-properties (point) (point-max)))
              (error "lark-org: %s"
                     (buffer-substring
                      (line-beginning-position)
                      (line-end-position)))))
        (kill-buffer buf)))))

(defun lark-org--api-url (path)
  "Return the absolute API URL for PATH."
  (concat (replace-regexp-in-string "/\\'" "" lark-org-api-base)
          "/open-apis/" path))

(defun lark-org--query-string (query)
  "Return QUERY (alist of string keys) as a hexified query string."
  (if (not query) ""
    (concat "?"
            (mapconcat
             (lambda (kv)
               (concat (url-hexify-string (format "%s" (car kv)))
                       "="
                       (url-hexify-string (format "%s" (cdr kv)))))
             query "&"))))

;;;; Auth (tenant_access_token; memory only, never logged)

(defvar lark-org--token nil
  "Cached tenant_access_token.  Memory only (section 9.10).")
(defvar lark-org--token-expiry 0
  "Absolute seconds after which the cached token counts stale.")

(defconst lark-org--token-error-codes '(99991661 99991663 99991668)
  "API codes meaning the tenant token is missing, invalid or
expired; the call is retried once with a fresh token.")

(defun lark-org--app-secret ()
  "Return the app secret from auth-source (never echoed)."
  (or (auth-source-pick-first-password
       :host (plist-get lark-org-secret-auth-source :host)
       :user (plist-get lark-org-secret-auth-source :user))
      (user-error "lark-org: no app secret in auth-source (host %s)"
                  (plist-get lark-org-secret-auth-source :host))))

(defun lark-org--fetch-token ()
  "Fetch and cache a fresh tenant_access_token."
  (unless (and (stringp lark-org-app-id) (not (equal lark-org-app-id "")))
    (user-error "lark-org: lark-org-app-id is unset"))
  (let ((obj (lark-org--decode-json
              (funcall lark-org-http-function
                       "POST"
                       (lark-org--api-url
                        "auth/v3/tenant_access_token/internal")
                       (list (cons "Content-Type"
                                   "application/json; charset=utf-8"))
                       (json-encode
                        (list (cons "app_id" lark-org-app-id)
                              (cons "app_secret"
                                    (lark-org--app-secret))))))))
    (lark-org--check-envelope obj)
    (let ((tok (alist-get 'tenant_access_token obj))
          (exp (alist-get 'expire obj)))
      (unless (stringp tok)
        (error "lark-org: auth response carries no token"))
      (setq lark-org--token tok
            lark-org--token-expiry
            (+ (float-time) (if (numberp exp) (- exp 300) 6900)))
      tok)))

(defun lark-org--token ()
  "Return a usable tenant token, refreshing the cache when stale."
  (if (and lark-org--token (< (float-time) lark-org--token-expiry))
      lark-org--token
    (lark-org--fetch-token)))

(defun lark-org--api-call (method path query &optional body authed retried)
  "Call PATH with METHOD, QUERY alist and JSON BODY.
When AUTHED, send the tenant token; on a token-error code refresh
the cache and retry ONCE (bounded).  Returns the decoded object."
  (let* ((url (concat (lark-org--api-url path)
                      (lark-org--query-string query)))
         (headers (cons (cons "Content-Type"
                              "application/json; charset=utf-8")
                        (when authed
                          (list (cons "Authorization"
                                      (concat "Bearer "
                                              (lark-org--token)))))))
         (obj (lark-org--decode-json
               (funcall lark-org-http-function
                        method url headers
                        (and body (json-encode body))))))
    (let ((code (alist-get 'code obj)))
      (if (and authed (not retried) (numberp code)
               (memq code lark-org--token-error-codes))
          (progn
            (setq lark-org--token nil lark-org--token-expiry 0)
            (lark-org--api-call method path query body authed 'retried))
        (lark-org--check-envelope obj)
        obj))))

(defun lark-org--fixture-index ()
  "Deterministic chat index for tests and demos."
  (list
   (list :id "oc_fixture_alice" :group "Pinned" :name "Alice"
         :unread 3 :mentions 0 :muted nil
         :last-time "2m" :last-dir 'in :last-text "call me tonight")
   (list :id "oc_fixture_hq" :group "Teams" :name "hq"
         :unread 0 :mentions 2 :muted nil
         :last-time "5m" :last-dir 'out :last-text
         "on it -- standard first")))

(defun lark-org--fixture-view (&optional _chat-id)
  "Deterministic conversation fixture for tests and demos.
Times are fixed so rendered stamps are stable; the text covers the
URL rule and the drawer-lookalike degradation (section 4 rule 3)."
  (list :id "oc_fixture_hq" :name "hq" :kind "group"
        :messages
        (list
         (list :id "om_1"
               :time (encode-time 0 56 18 3 11 2026)
               :author "kh." :handle "ou_khalid"
               :text "new project for you, lark-org\n\nsee https://example.org/brief\n\n:END: look-alike line"
               :out nil :unread 2 :mention nil)
         (list :id "om_2"
               :time (encode-time 0 58 18 3 11 2026)
               :author "me" :handle "ou_self"
               :text "on it -- standard first"
               :out t :unread nil :mention nil)
         (list :id "om_3"
               :time (encode-time 0 2 19 3 11 2026)
               :author "kh." :handle "ou_khalid"
               :text "second unread"
               :out nil :unread t :mention nil))))

;;;; Pure converters (Lark items -> standard plists)

(defun lark-org--group-for (chat-name)
  "Return the group for CHAT-NAME: first match wins (section 3
rule 1); no match goes to the fallback group."
  (let ((hit nil))
    (dolist (pair lark-org-group-alist)
      (when (and (not hit)
                 (string-match-p (car pair) chat-name))
        (setq hit (cdr pair))))
    (or hit lark-org-fallback-group)))

(defun lark-org--index-from-items (items)
  "Convert Lark chats ITEMS to the section 3 chat plists.
The chats endpoint carries no unread/mention model and no last
message preview -- tags are 0 and the preview is the honest
placeholder \"...\" (disclosed limit, see Commentary)."
  (mapcar
   (lambda (item)
     (let ((name (lark-org--s (alist-get 'name item))))
       (list :id (lark-org--s (alist-get 'chat_id item))
             :group (lark-org--group-for name)
             :name name
             :unread 0 :mentions 0 :muted nil
             :last-time "" :last-dir 'in :last-text "...")))
   items))

(defconst lark-org--kind-words
  '(("image" . "photo") ("audio" . "voice") ("media" . "video")
    ("file" . "file") ("sticker" . "sticker")
    ("share_chat" . "chat card") ("share_user" . "contact card"))
  "Kind words for textless message types (section 3 rule 4 analog).")

(defun lark-org--post-run (run)
  "Return the text of one rich-text RUN of a post message."
  (let ((tag (lark-org--s (alist-get 'tag run))))
    (cond ((string= tag "a")
           (let ((href (alist-get 'href run))
                 (text (lark-org--s (alist-get 'text run))))
             (if (and (stringp href) (not (equal href "")))
                 (format "[[%s][%s]]" href
                         (if (equal text "") href text))
               text)))
          ((string= tag "at")
           (concat "@" (lark-org--s (alist-get 'user_name run))))
          (t (lark-org--s (alist-get 'text run))))))

(defun lark-org--post-text (obj)
  "Return the plain text of a post content object OBJ."
  (let ((title (lark-org--s (alist-get 'title obj)))
        (lines nil))
    (dolist (para (alist-get 'content obj))
      (push (mapconcat #'lark-org--post-run para "") lines))
    (concat (if (equal title "") "" (concat title "\n"))
            (mapconcat #'identity (nreverse lines) "\n"))))

(defun lark-org--decode-content (msg-type raw)
  "Return the plain-text rendering of the Lark content string RAW
for MSG-TYPE (section 4 rule 3: no Org equivalent degrades to
plain text, never raw markup)."
  (let ((obj (condition-case nil
                 (lark-org--decode-json raw)
               (error nil))))
    (cond ((string= msg-type "text")
           (lark-org--s (alist-get 'text obj)))
          ((string= msg-type "post")
           (lark-org--post-text obj))
          (t (or (cdr (assoc msg-type lark-org--kind-words))
                 "card")))))

(defun lark-org--encode-text-content (text)
  "Encode TEXT as the Lark send content field.
The im/v1 send API double-encodes: content is a JSON *string*
carrying a JSON object -- this shape is pinned by an ERT."
  (json-encode (list (cons "text" text))))

(defun lark-org--message-from-item (item)
  "Convert one Lark history ITEM to a section 4 message plist."
  (let* ((id (lark-org--s (alist-get 'message_id item)))
         (ct (alist-get 'create_time item))
         (time (cond ((stringp ct)
                      (seconds-to-time (/ (string-to-number ct) 1000)))
                     ((numberp ct)
                      (seconds-to-time (/ ct 1000)))
                     (t nil)))
         (sender (alist-get 'sender item))
         (handle (lark-org--s (alist-get 'id sender)))
         (self (and (stringp lark-org-self-open-id)
                    (not (equal lark-org-self-open-id ""))
                    (string= handle lark-org-self-open-id)))
         (body (alist-get 'body item))
         (raw (and body (alist-get 'content body)))
         (text (if (stringp raw)
                   (lark-org--decode-content
                    (lark-org--s (alist-get 'msg_type item)) raw)
                 "")))
    (list :id id :time time
          :author (if self "me" handle)
          :handle handle
          :text text
          :out self :unread nil :mention nil)))

(defun lark-org--view-from-items (chat-id name kind items)
  "Convert Lark history ITEMS to a section 4 conversation plist."
  (list :id chat-id :name name :kind kind
        :messages (mapcar #'lark-org--message-from-item items)))

;;;; Live adapters (API-backed, fixture degradation on read)

(defun lark-org--live-index ()
  "Chat index from the Lark API; degrade to the fixture on error.
A live API answering zero chats renders an empty list -- reality,
not fixture."
  (condition-case nil
      (let* ((data (alist-get 'data
                              (lark-org--api-call
                               "GET" "im/v1/chats"
                               (list (cons "page_size"
                                           lark-org-page-size))
                               nil 'authed)))
             (items (alist-get 'items data)))
        (if (listp items)
            (lark-org--index-from-items items)
          (lark-org--fixture-index)))
    (error (lark-org--fixture-index))))

(defun lark-org--chat-meta (chat-id)
  "Return the chats-endpoint entry for CHAT-ID, or nil."
  (let* ((data (alist-get 'data
                          (lark-org--api-call
                           "GET" "im/v1/chats"
                           (list (cons "page_size"
                                       lark-org-page-size))
                           nil 'authed)))
         (items (alist-get 'items data)))
    (when (listp items)
      (cl-find chat-id items
               :key (lambda (it) (alist-get 'chat_id it))
               :test #'string=))))

(defun lark-org--kind-of (chat-type)
  "Map a Lark chat_type to the section 4 :KIND: vocabulary."
  (cond ((string= chat-type "p2p") "im")
        ((string= chat-type "group") "group")
        (t "im")))

(defun lark-org--history-items (chat-id)
  "Return up to `lark-org-max-pages' pages of history for CHAT-ID."
  (catch 'done
    (let ((out nil))
      (dotimes (_ lark-org-max-pages)
        (let* ((q (list (cons "container_id_type" "chat")
                        (cons "container_id" chat-id)
                        (cons "sort_type" "ByCreateTimeAsc")
                        (cons "page_size" lark-org-page-size)))
               (data (alist-get 'data
                                (lark-org--api-call
                                 "GET" "im/v1/messages" q
                                 nil 'authed)))
               (token (alist-get 'page_token data)))
          (setq out (append out (alist-get 'items data)))
          (unless (and (lark-org--truthy (alist-get 'has_more data))
                       (stringp token) (not (equal token "")))
            (throw 'done out))))
      out)))

(defun lark-org--live-view (&optional chat-id)
  "Conversation CHAT-ID from the Lark API; degrade on error.
A nil chat id goes straight to the fixture (nothing to fetch)."
  (if (not chat-id)
      (lark-org--fixture-view chat-id)
    (condition-case nil
        (let* ((meta (lark-org--chat-meta chat-id))
               (name (if (and meta (alist-get 'name meta))
                         (lark-org--s (alist-get 'name meta))
                       chat-id))
               (kind (lark-org--kind-of
                      (lark-org--s (and meta
                                        (alist-get 'chat_type meta)))))
               (items (lark-org--history-items chat-id)))
          (lark-org--view-from-items chat-id name kind items))
      (error (lark-org--fixture-view chat-id)))))

(defun lark-org--live-send (chat-id text)
  "Send TEXT to CHAT-ID via the Lark API.
Returns the backend message_id for the :MSG-ID: stamp; signals on
any failure so the draft keeps its :draft: tag (section 4 rule 8)
-- a write path must never degrade silently to the fixture."
  (unless (and (stringp lark-org-app-id)
               (not (equal lark-org-app-id "")))
    (user-error "lark-org: lark-org-app-id is unset; cannot send"))
  (let ((obj (lark-org--api-call
              "POST" "im/v1/messages"
              (list (cons "receive_id_type" "chat_id"))
              (list (cons "receive_id" chat-id)
                    (cons "msg_type" "text")
                    (cons "content"
                          (lark-org--encode-text-content text)))
              'authed)))
    (lark-org--s (alist-get 'message_id (alist-get 'data obj)))))

;;;; Shared render helpers

(defun lark-org--strip (s)
  "Return string S with all text properties stripped."
  (substring-no-properties (or s "")))

(defun lark-org--kind-word (text)
  "Return TEXT if non-empty, else a kind word for a textless item."
  (let ((s (lark-org--strip text)))
    (if (string-empty-p s) "message" s)))

(defun lark-org--preview-line (chat)
  "Return the preview line for CHAT: time, arrow, one-line text."
  (let* ((time (lark-org--strip (plist-get chat :last-time)))
         (arrow (if (eq (plist-get chat :last-dir) 'out) "↑" "↓"))
         (text (lark-org--kind-word (plist-get chat :last-text))))
    (concat "  "
            (propertize time 'face 'lark-org-time-face)
            "  " arrow " "
            (propertize text 'face 'lark-org-preview-face))))

(defun lark-org--heading-line (chat)
  "Return the level-2 heading line for CHAT."
  (let ((name (lark-org--strip (plist-get chat :name)))
        (tags ""))
    (let ((unread (plist-get chat :unread)))
      (when (and (numberp unread) (> unread 0))
        (setq tags (concat tags
                           (propertize (format " :unread:%d:" unread)
                                       'face 'lark-org-unread-face)))))
    (let ((mentions (plist-get chat :mentions)))
      (when (and (numberp mentions) (> mentions 0))
        (setq tags (concat tags
                           (propertize (format " :mention:%d:" mentions)
                                       'face 'lark-org-mention-face)))))
    (when (plist-get chat :muted) (setq tags (concat tags " :mute:")))
    (let ((display
           (if (equal (plist-get chat :id) lark-org-current-chat-id)
               (propertize name 'face 'lark-org-current-face)
             name)))
      (concat "** " display tags))))

(defun lark-org--insert-chat (chat)
  "Insert CHAT as a level-2 heading plus preview line at point."
  (let* ((id (lark-org--strip (plist-get chat :id)))
         (heading (lark-org--heading-line chat))
         (preview (lark-org--preview-line chat)))
    ;; The heading carries the chat id as a text property; the id is
    ;; an opaque backend value, never displayed (section 5).
    (insert (propertize heading 'lark-org-chat-id id) "\n")
    (insert preview "\n")))

;;;; List buffer (standard section 3)

;;;###autoload
(defun lark-org-render ()
  "Render the chat list into the buffer \"*Lark Org*\".
Level 1 holds the groups (first-seen order), level 2 one chat per
exactly two lines.  The buffer is org-mode, read-only and
undo-disabled (section 8).  Return the buffer."
  (interactive)
  (let ((buf (get-buffer-create "*Lark Org*"))
        (chats (funcall lark-org-index-function)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (buffer-disable-undo)
        (erase-buffer)
        (org-mode)
        (let ((groups nil))
          (dolist (chat chats)
            (let* ((group (lark-org--strip (plist-get chat :group)))
                   (cell (assoc group groups)))
              (if cell
                  (push chat (cdr cell))
                (push (list group chat) groups))))
          (dolist (group (nreverse groups))
            (insert "* " (car group) "\n")
            (dolist (chat (nreverse (cdr group)))
              (lark-org--insert-chat chat))))
        (goto-char (point-min))
        (setq buffer-read-only t)
        (lark-org-list-mode 1)
        (when (and lark-org-adapt-for-touch (lark-org--touch-device-p))
          (lark-org--setup-touch))))
    buf))

;;;###autoload
(defun lark-org ()
  "Open the Lark chat list."
  (interactive)
  (pop-to-buffer (lark-org-render)))

(defun lark-org-chat-id-at-point ()
  "Return the chat id text property at point, or nil."
  (get-text-property (point) 'lark-org-chat-id))

(defun lark-org--chat-id-here ()
  "Return the chat id at point, or nil.  The preview line under a
chat heading belongs to that chat."
  (or (lark-org-chat-id-at-point)
      (save-excursion
        (and (= (forward-line -1) 0)
             (lark-org-chat-id-at-point)))))

;;;; View internals (standard section 4)

(declare-function org-cycle-set-startup-visibility "org-cycle" nil)
(declare-function org-fold-show-entry "org-fold" nil)

(defun lark-org--startup-visibility ()
  "Fold the buffer per the STARTUP options (Org 9.5/9.6+ compat)."
  (if (fboundp 'org-cycle-set-startup-visibility)
      (org-cycle-set-startup-visibility)
    (with-no-warnings (org-set-startup-visibility))))

(defun lark-org--show-entry ()
  "Make the current entry visible (Org 9.5/9.6+ compat)."
  (if (fboundp 'org-fold-show-entry)
      (org-fold-show-entry)
    (with-no-warnings (org-show-entry))))

(defvar lark-org--view-chat-id nil
  "Chat id of the current view buffer, or nil.")
(make-variable-buffer-local 'lark-org--view-chat-id)
(put 'lark-org--view-chat-id 'permanent-local t)

(defvar lark-org--view-unread-p nil
  "Non-nil while an :unread: marker waits in the current view.")
(make-variable-buffer-local 'lark-org--view-unread-p)
(put 'lark-org--view-unread-p 'permanent-local t)

(defun lark-org--view-count-tag (name count)
  "Return the tag text for NAME with COUNT: a numeric pair for
N>0 (section 5), a bare tag for t, nothing for nil or zero."
  (cond ((not count) "")
        ((and (numberp count) (> count 0))
         (format " :%s:%d:" name count))
        ((numberp count) "")
        (t (format " :%s:" name))))

(defun lark-org--view-unread-marked-p (count)
  "Return non-nil when COUNT marks an actual unread state."
  (and count (or (not (numberp count)) (> count 0))))

(defun lark-org--view-tags (msg)
  "Return the propertized tag text for MSG, or \"\"."
  (concat
   (let ((tag (lark-org--view-count-tag "unread"
                                        (plist-get msg :unread))))
     (if (equal tag "") ""
       (propertize tag 'face 'lark-org-unread-face)))
   (let ((tag (lark-org--view-count-tag "mention"
                                        (plist-get msg :mention))))
     (if (equal tag "") ""
       (propertize tag 'face 'lark-org-mention-face)))
   (if (plist-get msg :out) " :out:" "")))

(defun lark-org--view-stamp (time)
  "Return the inactive [YYYY-MM-DD Day HH:MM] stamp for TIME.
Inactive per section 4 rule 2 (the agenda must never fire).  A
time that is neither a list nor a number degrades to [---]."
  (propertize (if (or (consp time) (numberp time))
                  (format-time-string "[%Y-%m-%d %a %H:%M]" time)
                "[---]")
              'face 'lark-org-time-face))

(defun lark-org--view-one-line (s)
  "Return S stripped and collapsed to one trimmed line."
  (let ((s (replace-regexp-in-string "[[:space:]]+" " "
                                     (lark-org--strip s))))
    (replace-regexp-in-string "\\` +\\| +\\'" "" s)))

(defun lark-org--view-author (msg)
  "Return the display author of MSG for the heading line."
  (let ((a (lark-org--view-one-line (plist-get msg :author))))
    (if (equal a "") "unknown" a)))

(defun lark-org--view-prop-value (v)
  "Return V as a single-line opaque property value, or \"-\"."
  (let ((s (lark-org--view-one-line (or v ""))))
    (if (equal s "") "-" s)))

(defun lark-org--view-body (text)
  "Return the indented body block for TEXT, or \"\".
Blank-line runs split paragraphs; URLs become Org links; a line
that could parse as a drawer or :END: gets a space after its
leading colon, so backend text can never corrupt the structure
(section 4 rule 3: degrade to plain text)."
  (let* ((text (replace-regexp-in-string "https?://[^[:space:]]+"
                                         "[[\\&]]"
                                         (lark-org--strip text)))
         (blocks nil))
    (dolist (para (split-string text "\n[ \t]*\n" t))
      (push (mapconcat
             (lambda (line)
               (concat "   "
                       (if (string-match-p "^[ \t]*:" line)
                           (replace-regexp-in-string "^[ \t]*:" "\\& " line)
                         line)))
             (split-string para "\n" t)
             "\n")
            blocks))
    (mapconcat #'identity (nreverse blocks) "\n\n")))

(defun lark-org--view-message-block (msg)
  "Return the full Org block for MSG: heading, drawer, body."
  (concat "** "
          (lark-org--view-stamp (plist-get msg :time))
          " "
          (lark-org--view-author msg)
          (lark-org--view-tags msg)
          "\n"
          "   :PROPERTIES:\n"
          "   :MSG-ID:  "
          (lark-org--view-prop-value (plist-get msg :id)) "\n"
          "   :AUTHOR:  "
          (lark-org--view-prop-value
           (or (plist-get msg :handle) (plist-get msg :author))) "\n"
          "   :END:\n"
          (let ((body (lark-org--view-body (plist-get msg :text))))
            (if (equal body "") "" (concat body "\n")))))

(defun lark-org--view-kind (conv)
  "Return the :KIND: value for CONV, clamped to the section 4 set."
  (let ((k (downcase (lark-org--view-one-line
                      (plist-get conv :kind)))))
    (if (member k '("im" "group" "channel")) k "im")))

(defun lark-org--view-display-name (conv)
  "Return the buffer-name-safe display name for CONV."
  (let ((n (lark-org--view-one-line (plist-get conv :name))))
    (when (equal n "")
      (setq n (lark-org--view-one-line (plist-get conv :id))))
    (if (equal n "") "chat" n)))

(defconst lark-org--view-tags-re
  "[ \t]\\(:[[:alnum:]_@#%:]+:\\(?:[ \t]*:[[:alnum:]_@#%:]+:\\)*\\)"
  "Match one whitespace-led run of tag chunks; group 1 is the run.
The view owns the heading grammar (section 4 rule 2), so tags are
parsed from the line text; Org's element cache is never involved.")

(defun lark-org--view-line-tags (line)
  "Return the tag list carried by view heading LINE, or nil."
  (when (string-match (concat lark-org--view-tags-re "\\'") line)
    (split-string (match-string 1 line) ":" t)))

(defun lark-org--first-tagged-position (tag)
  "Return the position of the first level-2 heading carrying TAG,
or nil.  A plain line walk over the chunks the package renders
itself; works in the list and the view, folded or not."
  (save-excursion
    (goto-char (point-min))
    (catch 'found
      (while (not (eobp))
        (when (looking-at-p "\\*\\* ")
          (let ((tags (lark-org--view-line-tags
                       (buffer-substring-no-properties
                        (line-beginning-position)
                        (line-end-position)))))
            (when (and tags (member tag tags))
              (throw 'found (line-beginning-position)))))
        (forward-line 1)))))

(defun lark-org--view-unread-position ()
  "Return the position of the first :unread:-tagged message, or nil."
  (lark-org--first-tagged-position "unread"))

(defun lark-org--view-clear-unread (pos)
  "Remove the unread marker tags from the message heading at POS.
Direct string surgery on the chunk the view renders itself; the
numeric partner of each cleared tag goes with it (section 5 pair).
Remaining tags (e.g. :out:) are rebuilt as one chunk."
  (save-excursion
    (goto-char pos)
    (beginning-of-line)
    (let* ((bol (point))
           (line (buffer-substring-no-properties
                  bol (line-end-position)))
           (tags (lark-org--view-line-tags line)))
      (when (and tags (member "unread" tags))
        (let ((keep nil))
          (dolist (tag tags)
            (unless (or (member tag '("unread" "mention"))
                        (string-match-p "\\`[0-9]+\\'" tag))
              (push tag keep)))
          (setq keep (nreverse keep))
          (string-match (concat lark-org--view-tags-re "\\'") line)
          (let ((inhibit-read-only t)
                (beg (+ bol (match-beginning 0)))
                (end (+ bol (match-end 0))))
            (delete-region beg end)
            (when keep
              (goto-char beg)
              (insert (concat " "
                              (mapconcat
                               (lambda (tag) (concat ":" tag ":"))
                               keep "")))))
          (setq lark-org--view-unread-p nil))))))

(defun lark-org--view-unread-watch ()
  "Clear the unread marker once point moves past its message.
Buffer-local `post-command-hook' installed by the view renderer
(section 4 rule 7)."
  (when (and lark-org--view-unread-p
             (derived-mode-p 'org-mode)
             lark-org--view-chat-id)
    (let ((pos (lark-org--view-unread-position)))
      (cond ((not pos)
             (setq lark-org--view-unread-p nil))
            ((> (point)
                (save-excursion (goto-char pos) (line-end-position)))
             (lark-org--view-clear-unread pos))))))

;;;###autoload
(defun lark-org-view-render (&optional chat-id)
  "Render conversation CHAT-ID into the buffer \"*Lark Org: <chat>*\".
The conversation comes from `lark-org-view-fetch-function'.  The
buffer is org-mode, read-only and undo-disabled (section 8),
starts with #+STARTUP: overview, and carries one level-1 entry
with the CHAT-ID/KIND drawer plus one level-2 entry per message
(section 4, rules 1-5).  Only the FIRST unread message carries the
marker (rule 7).  The buffer is rebuilt from scratch on every
call -- a fresh buffer carries fresh Org state (fold registry,
element cache) -- and windows on the old buffer are re-pointed.
Return the buffer."
  (let* ((conv (funcall lark-org-view-fetch-function chat-id))
         (name (lark-org--view-display-name conv))
         (bname (concat "*Lark Org: " name "*"))
         (old (get-buffer bname))
         (windows (and old (get-buffer-window-list old nil t))))
    (when old
      (with-current-buffer old (rename-buffer " *Lark Org-old*" t)))
    (let ((buf (get-buffer-create bname)))
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (has-unread nil))
          (erase-buffer)
          (insert "#+STARTUP: overview\n\n")
          (insert "* " name "\n"
                  ":PROPERTIES:\n"
                  ":CHAT-ID:  "
                  (lark-org--view-prop-value (plist-get conv :id))
                  "\n"
                  ":KIND:     " (lark-org--view-kind conv) "\n"
                  ":END:\n")
          (let ((unread-left t))
            (dolist (msg (plist-get conv :messages))
              (if (and unread-left
                       (lark-org--view-unread-marked-p
                        (plist-get msg :unread)))
                  (progn
                    (setq unread-left nil has-unread t)
                    (insert (lark-org--view-message-block msg)))
                (insert (lark-org--view-message-block
                         (plist-put (copy-sequence msg)
                                    :unread nil))))))
          (org-mode)
          ;; Folded chat text must stay searchable (section 1).
          (setq-local search-invisible t)
          (lark-org--startup-visibility)
          (setq lark-org--view-chat-id
                (lark-org--view-prop-value (plist-get conv :id)))
          (setq lark-org--view-unread-p has-unread)
          (buffer-disable-undo)
          (goto-char (point-min))
          (setq buffer-read-only t)
          (add-hook 'post-command-hook
                    #'lark-org--view-unread-watch nil t)
          (lark-org-view-mode 1)
          (when (and lark-org-adapt-for-touch
                     (lark-org--touch-device-p))
            (lark-org--setup-touch))))
      (dolist (w windows) (set-window-buffer w buf))
      (when old (kill-buffer old))
      buf)))

;;;###autoload
(defun lark-org-view-append (msg)
  "Append message MSG at point-max of the current view buffer.
Live-update primitive (section 4 rule 6): the insert goes through
`inhibit-read-only' inside package code, undo stays disabled, and
point (the buffer's and each displayed window's) follows the new
message only when it was already at point-max.  When the
conversation is folded (STARTUP overview), the fold is restored
afterwards.  Return the buffer."
  (unless (and (derived-mode-p 'org-mode) lark-org--view-chat-id)
    (user-error "Not a lark-org view buffer"))
  (let ((inhibit-read-only t)
        (folded (and (> (point-max) (point-min))
                     (org-invisible-p (1- (point-max)))))
        (was-at-bottom (>= (point) (point-max)))
        (wins nil))
    (dolist (w (get-buffer-window-list nil nil t))
      (when (>= (window-point w) (point-max))
        (push w wins)))
    (save-excursion
      (goto-char (point-max))
      (insert (lark-org--view-message-block msg)))
    (when folded
      ;; An insert at the folded boundary can disturb the fold of the
      ;; adjacent text (org-fold-core); restoring the STARTUP fold
      ;; leaves the buffer in the documented overview state.
      (lark-org--startup-visibility))
    (when (lark-org--view-unread-marked-p (plist-get msg :unread))
      (setq lark-org--view-unread-p t))
    (when was-at-bottom (goto-char (point-max)))
    (dolist (w wins) (set-window-point w (point-max)))
    (current-buffer)))

;;;###autoload
(defun lark-org-jump-unread ()
  "Put point on the first unread entry of the current buffer.
In the view the first message tagged :unread: (section 4 rule 7);
in the list the first chat tagged :unread: (section 3).  The entry
is made visible and point moves to its heading."
  (interactive)
  (let ((pos (lark-org--first-tagged-position "unread")))
    (if (not pos)
        (user-error "No unread entry here")
      (goto-char pos)
      (lark-org--show-entry))))

;;;; Section 7 verbs (both buffers)

(defun lark-org-quit ()
  "Bury the list or view buffer (section 8: q buries, never kills)."
  (interactive)
  (bury-buffer))

(defun lark-org--adjacent-chat-position (back)
  "Return the position of the chat heading adjacent to point.
Walks outline headings in direction BACK (invisible or not,
across level-1 group boundaries) until a level-2 chat heading is
found; nil at the ends of the list.  An explicit walk because
`org-forward-heading-same-level' skips whole subtrees by default
and its no-skip mode does not cross group boundaries.

Walking backward from a preview line skips the chat whose subtree
strictly contains the starting line (the repaired walk), so the
previous chat is reached; point ON a chat heading still walks to
the previous chat."
  (save-excursion
    (let ((start (point)))
      (catch 'found
        (while (if back
                   (outline-previous-heading)
                 (outline-next-heading))
          (when (= (org-current-level) 2)
            (if (and back
                     (> start (point))
                     (<= start
                         (save-excursion
                           (goto-char (point))
                           (org-end-of-subtree t))))
                nil
              (throw 'found (point)))))
        nil))))

(defun lark-org-next-chat (&optional back)
  "Move point to the next chat heading; with BACK to the previous.
Section 7 next/prev verb for the list buffer; signals at the ends."
  (interactive)
  (let ((pos (lark-org--adjacent-chat-position back)))
    (if pos
        (goto-char pos)
      (user-error "No %s chat" (if back "previous" "next")))))

(defun lark-org-previous-chat ()
  "Move point to the previous chat heading (section 7)."
  (interactive)
  (lark-org-next-chat 'back))

(defun lark-org-refresh ()
  "Refresh the current surface (section 7).  In a view buffer this
delegates to `lark-org-view-refresh' so g refreshes the surface it
was invoked on; in any other org buffer it re-renders the list."
  (interactive)
  (cond ((and (eq major-mode 'org-mode) lark-org--view-chat-id)
         (lark-org-view-refresh))
        ((eq major-mode 'org-mode)
         (lark-org-render))
        (t (user-error "Not a lark-org buffer"))))

(defun lark-org-view-refresh ()
  "Refresh the current view from `lark-org-view-fetch-function'."
  (interactive)
  (unless lark-org--view-chat-id
    (user-error "Not a lark-org view buffer"))
  ;; Render kills and rebuilds this buffer; adopt the fresh one.
  (set-buffer (lark-org-view-render lark-org--view-chat-id)))

(defun lark-org-open-at-point ()
  "Open the chat at point in its Org view (section 7 hand-off).
Works on the chat heading and on its preview line."
  (interactive)
  (let ((id (lark-org--chat-id-here)))
    (unless id
      (user-error "No chat at point"))
    (pop-to-buffer (lark-org-view-render id))))

;;;; Touch adaptation (section 7)

(defun lark-org--touch-device-p ()
  "Return non-nil when Emacs runs on a touch device: the Android
port, a Termux environment, or a terminal advertising touch."
  (or (eq system-type 'android)
      (getenv "TERMUX_VERSION")
      (let ((found nil))
        (dolist (frame (frame-list) found)
          (when (terminal-parameter frame 'touch-screen)
            (setq found t))))))

(defun lark-org-tap ()
  "Do what a tap on the line at point means (section 7 touch law).
A chat opens, a heading folds and unfolds with Org's `org-cycle',
anything else is an error."
  (interactive)
  (cond ((lark-org--chat-id-here)
         (lark-org-open-at-point))
        ((save-excursion
           (beginning-of-line)
           (looking-at-p "\\*+ "))
         (org-cycle))
        (t (user-error "Nothing to tap here"))))

(defun lark-org--tap-mouse (event)
  "Tap: position point at EVENT and run `lark-org-tap'."
  (interactive "e")
  (mouse-set-point event)
  (lark-org-tap))

(defvar lark-org-touch-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'lark-org--tap-mouse)
    map)
  "Touch bindings, enabled per buffer on touch devices only.
The shared list/view maps are never mutated (section 7).")

;;;###autoload
(define-minor-mode lark-org-touch-mode
  "Touch bindings for the lark-org chat buffers."
  :init-value nil
  :lighter nil
  :keymap lark-org-touch-mode-map)

(defun lark-org--setup-touch ()
  "Enable the touch bindings in the current buffer (section 7)."
  (lark-org-touch-mode 1)
  (setq-local scroll-conservatively 101)
  (setq-local truncate-lines t))

;;;; Section 4 rule 8: drafts and sends

(defvar lark-org-self-handle "me"
  "Display author of own messages (section 4 rule 2).")

(defun lark-org--view-entry-tags ()
  "Return the local tag list of the entry at point, or nil.
Nil when point sits outside any entry, so compose can append a
fresh draft instead of signaling."
  (save-excursion
    (when (ignore-errors (org-back-to-heading t))
      (lark-org--view-line-tags
       (buffer-substring-no-properties
        (line-beginning-position) (line-end-position))))))

(defun lark-org--view-draft-block (text)
  "Return the Org block of a :draft: entry carrying TEXT."
  (concat "** "
          (lark-org--view-stamp (current-time))
          " " lark-org-self-handle " :draft:\n"
          "   :PROPERTIES:\n"
          "   :AUTHOR:  "
          (lark-org--view-prop-value lark-org-self-handle) "\n"
          "   :END:\n"
          (let ((body (lark-org--view-body text)))
            (if (equal body "") "" (concat body "\n")))))

(defun lark-org--view-insert-at-max (block &optional reveal)
  "Insert BLOCK at point-max of the current view buffer.
Point (buffer and windows) follows only when it was already at the
bottom; a folded conversation is restored to the STARTUP fold,
unless REVEAL, then the inserted entry is made visible.  Return
the position of the inserted block's beginning."
  (let* ((inhibit-read-only t)
         (old-max (point-max))
         (folded (and (> old-max (point-min))
                      (org-invisible-p (1- old-max))))
         (was-at-bottom (>= (point) old-max))
         (wins nil))
    (dolist (w (get-buffer-window-list nil nil t))
      (when (>= (window-point w) old-max)
        (push w wins)))
    (save-excursion
      (goto-char old-max)
      (insert block)
      (when folded
        (lark-org--startup-visibility)))
    (when reveal
      (save-excursion
        (goto-char old-max)
        (org-back-to-heading t)
        (lark-org--show-entry)))
    (when was-at-bottom (goto-char (point-max)))
    (dolist (w wins) (set-window-point w (point-max)))
    old-max))

(defun lark-org-view-compose (&optional text send-now)
  "Compose a message in the current view buffer (section 4 rule 8).
Interactively TEXT is read from the minibuffer; a prefix argument
sends it immediately instead of leaving a draft.  A view holds at
most one :draft: entry: with point on the draft its body is
replaced in place; with point elsewhere an existing draft is
likewise replaced in place (the new text wins) and point moves to
it, revealed; only when no draft exists is a new one appended at
point-max, tagged :draft: with author \"me\".  Composing never
touches the network."
  (interactive (list (read-string "Message: ") current-prefix-arg))
  (unless (and (derived-mode-p 'org-mode) lark-org--view-chat-id)
    (user-error "Not a lark-org view buffer"))
  (unless (and (stringp text)
               (not (string-match-p "\\`[ \t\n]*\\'" text)))
    (user-error "Empty message"))
  (setq text (lark-org--strip text))
  (if send-now
      (condition-case err
          (let ((msg-id (funcall lark-org-send-function
                                 lark-org--view-chat-id text)))
            (lark-org--view-insert-at-max
             (lark-org--view-message-block
              (list :id msg-id :time (current-time)
                    :author lark-org-self-handle
                    :handle lark-org-self-handle
                    :text text :out t :unread nil :mention nil))))
        ;; A failed prefix send never loses the composed text.
        (error
         (lark-org--view-insert-at-max
          (lark-org--view-draft-block text))
         (signal (car err) (cdr err))))
    (let* ((tags (lark-org--view-entry-tags))
           (edit (and tags (member "draft" tags)))
           (block (lark-org--view-draft-block text))
           (draft-pos (unless edit
                        (lark-org--first-tagged-position "draft"))))
      (cond (edit
             (let ((inhibit-read-only t)
                   (beg (progn (org-back-to-heading t) (point)))
                   (end (save-excursion
                          (org-end-of-subtree t) (point))))
               (delete-region beg end)
               (goto-char beg)
               (insert block)
               (lark-org--show-entry)))
            (draft-pos
             (let ((inhibit-read-only t))
               (goto-char draft-pos)
               (delete-region draft-pos
                              (save-excursion
                                (org-end-of-subtree t)
                                (point)))
               (insert block)
               (goto-char draft-pos))
             (lark-org--show-entry))
            (t (lark-org--view-insert-at-max block 'reveal))))))

(defun lark-org--view-draft-text (entry-bol)
  "Return the unindented body text of the draft entry at ENTRY-BOL."
  (save-excursion
    (goto-char entry-bol)
    (let ((end (org-end-of-subtree t)))
      (goto-char entry-bol)
      (forward-line 1)
      (while (and (< (point) end) (not (looking-at-p "[ \t]*:END:")))
        (forward-line 1))
      (when (looking-at-p "[ \t]*:END:")
        (forward-line 1))
      (let ((lines nil))
        (while (< (point) end)
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position)
                       (line-end-position))))
            (push (if (string-prefix-p "   " line)
                      (substring line 3)
                    line)
                  lines))
          (forward-line 1))
        (let ((text (mapconcat #'identity (nreverse lines) "\n")))
          (replace-regexp-in-string "[ \t\n]+\\'" "" text))))))

(defun lark-org-view-send-draft ()
  "Send the :draft: entry at point (section 4 rule 8).
Calls `lark-org-send-function' with the view's chat id and the
draft body; on success the entry is retagged :out: and the
assigned :MSG-ID: is stamped into the drawer.  If the send
signals, the draft stays :draft: and nothing is edited."
  (interactive)
  (unless (and (derived-mode-p 'org-mode) lark-org--view-chat-id)
    (user-error "Not a lark-org view buffer"))
  (condition-case nil
      (org-back-to-heading t)
    (error (user-error "Point is not on a draft message")))
  (unless (member "draft" (lark-org--view-entry-tags))
    (user-error "Point is not on a draft message"))
  (let* ((bol (progn (org-back-to-heading t) (point)))
         (text (lark-org--view-draft-text bol))
         (msg-id (funcall lark-org-send-function
                          lark-org--view-chat-id text))
         (inhibit-read-only t))
    (goto-char bol)
    (let ((line (buffer-substring-no-properties
                 (line-beginning-position) (line-end-position))))
      (unless (string-match (concat lark-org--view-tags-re "\\'") line)
        (user-error "Draft tag chunk missing"))
      (let ((beg (+ (line-beginning-position) (match-beginning 1)))
            (end (+ (line-beginning-position) (match-end 1))))
        (delete-region beg end)
        (goto-char beg)
        (insert ":out:")))
    (goto-char bol)
    (forward-line 1)
    (unless (looking-at-p "[ \t]*:PROPERTIES:")
      (user-error "Draft drawer missing"))
    (end-of-line)
    ;; A backend that returns no id leaves the drawer without one
    ;; (section 5: entries may omit :MSG-ID:) -- never stamp a
    ;; placeholder value into the machine-read drawer.
    (when (and msg-id (not (equal msg-id "")))
      (insert "\n   :MSG-ID:  "
              (lark-org--view-prop-value msg-id)))
    (goto-char bol)))

;;;###autoload
(defun lark-org-send (text)
  "Send TEXT to the current view's chat (minibuffer send, rule 8).
The touch-friendly send path: on failure the composed text is
kept as a :draft: entry."
  (interactive "sMessage: ")
  (lark-org-view-compose text 'send-now))

;;;; Minor modes carrying the verbs

(defvar lark-org-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'lark-org-open-at-point)
    (define-key map "g" #'lark-org-refresh)
    (define-key map "j" #'lark-org-jump-unread)
    (define-key map "n" #'lark-org-next-chat)
    (define-key map "p" #'lark-org-previous-chat)
    (define-key map "q" #'lark-org-quit)
    map)
  "Keymap for the chat-list verbs (standard section 7).")

(defvar lark-org-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'lark-org-view-refresh)
    (define-key map "j" #'lark-org-jump-unread)
    (define-key map "q" #'lark-org-quit)
    (define-key map "c" #'lark-org-view-compose)
    (define-key map "\C-c\C-c" #'lark-org-view-send-draft)
    map)
  "Keymap for the chat-view verbs (sections 7 + 4 rule 8).")

;;;###autoload
(define-minor-mode lark-org-list-mode
  "Verbs for the \"*Lark Org*\" chat list (standard section 7)."
  :init-value nil
  :lighter nil
  :keymap lark-org-list-mode-map)

;;;###autoload
(define-minor-mode lark-org-view-mode
  "Verbs for the \"*Lark Org: <chat>*\" view (sections 7 + 4.8)."
  :init-value nil
  :lighter nil
  :keymap lark-org-view-mode-map)

(provide 'lark-org)
;;; lark-org.el ends here
