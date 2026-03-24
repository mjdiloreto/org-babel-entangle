;;; org-babel-entangle.el --- Lift directory trees into org-babel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Matthew DiLoreto

;; Author: Matthew DiLoreto
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (org "9.4"))
;; Keywords: org, literate-programming, tools
;; URL: https://github.com/mjdiloreto/org-babel-entangle

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; org-babel-entangle provides the missing "lift" operation for org-babel's
;; tangle/detangle workflow.  Given a directory of source files, it generates
;; an org file that round-trips through `org-babel-tangle':
;;
;;   Directory --[entangle]--> Org --[tangle]--> Directory'
;;
;; The generated org file uses `:comments link' so that `org-babel-detangle'
;; works from day one, enabling bidirectional sync between the org file and
;; tangled source files.
;;
;; Usage:
;;   M-x org-babel-entangle-directory RET /path/to/project RET
;;
;; Batch mode:
;;   emacs --batch -l org-babel-entangle.el \
;;     -f org-babel-entangle-batch /path/to/dir output.org

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)

;;;; Customization

(defgroup org-babel-entangle nil
  "Lift directory trees into org-babel."
  :group 'org-babel
  :prefix "org-babel-entangle-")

(defcustom org-babel-entangle-language-alist
  '((".md" . "markdown") (".sh" . "bash") (".js" . "js") (".cjs" . "js")
    (".ts" . "typescript") (".py" . "python") (".html" . "html")
    (".json" . "json") (".yml" . "yaml") (".yaml" . "yaml")
    (".txt" . "text") (".dot" . "dot") (".cmd" . "sh")
    (".el" . "emacs-lisp") (".go" . "go") (".rs" . "rust")
    (".rb" . "ruby") (".css" . "css") (".sql" . "sql")
    (".toml" . "toml") (".cfg" . "conf") (".ini" . "conf")
    (".org" . "org") (".xml" . "xml") (".c" . "C") (".h" . "C")
    (".cpp" . "C++") (".java" . "java") (".lua" . "lua")
    (".pl" . "perl") (".r" . "R") (".R" . "R")
    (".swift" . "swift") (".kt" . "kotlin") (".sc" . "scala")
    (".hs" . "haskell") (".ml" . "ocaml") (".ex" . "elixir")
    (".exs" . "elixir") (".erl" . "erlang") (".clj" . "clojure")
    (".lisp" . "lisp") (".scm" . "scheme") (".rkt" . "racket")
    (".fish" . "fish"))
  "Alist mapping file extensions to org-babel language identifiers."
  :type '(alist :key-type string :value-type string)
  :group 'org-babel-entangle)

(defcustom org-babel-entangle-name-language-alist
  '(("Makefile" . "makefile") ("Dockerfile" . "dockerfile")
    ("Vagrantfile" . "ruby") ("Rakefile" . "ruby")
    ("Gemfile" . "ruby") ("Justfile" . "makefile")
    (".gitignore" . "conf") (".dockerignore" . "conf")
    (".editorconfig" . "conf"))
  "Alist mapping exact filenames to org-babel language identifiers."
  :type '(alist :key-type string :value-type string)
  :group 'org-babel-entangle)

(defcustom org-babel-entangle-exclude-directories
  '("node_modules" ".git" "__pycache__" ".tox" "target" "dist" "build"
    ".eggs" ".mypy_cache" ".pytest_cache" ".venv" "venv" ".claude")
  "Directory names to exclude from scanning."
  :type '(repeat string)
  :group 'org-babel-entangle)

(defcustom org-babel-entangle-exclude-files
  '("package-lock.json" "yarn.lock" "Cargo.lock" ".DS_Store"
    "Thumbs.db" "desktop.ini")
  "File names to exclude from scanning."
  :type '(repeat string)
  :group 'org-babel-entangle)

(defcustom org-babel-entangle-no-comment-languages
  '("json" "text" "markdown" "dot" "toml" "org" "xml"
    "yaml" "typescript" "go" "rust" "kotlin" "scala"
    "haskell" "ocaml" "elixir" "erlang" "clojure"
    "racket" "R" "swift" "fish" "dockerfile")
  "Languages that get `:comments no' (no safe comment syntax).
Includes languages without built-in Emacs modes that define comment syntax.
All other languages get `:comments link' for detangle compatibility.
Languages with built-in comment support: emacs-lisp, python, bash, sh,
js, C, C++, java, ruby, perl, css, sql, makefile, conf, lua, lisp,
scheme, html."
  :type '(repeat string)
  :group 'org-babel-entangle)

(defcustom org-babel-entangle-startup "overview"
  "Value for #+STARTUP in generated org file."
  :type 'string
  :group 'org-babel-entangle)

(defcustom org-babel-entangle-auto-tangle t
  "Whether to add `org-auto-tangle-mode' file-local variable."
  :type 'boolean
  :group 'org-babel-entangle)

(defcustom org-babel-entangle-layout 'directory-tree
  "How to organize files into org headings.
`directory-tree' mirrors the filesystem hierarchy.
`flat' puts all files at the same heading level."
  :type '(choice (const :tag "Mirror directory tree" directory-tree)
                 (const :tag "Flat list" flat))
  :group 'org-babel-entangle)

;;;; Data structures

(cl-defstruct org-babel-entangle-entry
  "Represents a single file to be entangled into org."
  path           ; absolute path
  rel-path       ; relative to root directory
  content        ; string (file contents, decoded)
  raw-bytes      ; unibyte string (for newline detection)
  lang           ; org-babel language ID
  executable-p   ; needs :tangle-mode o755
  shebang        ; the shebang line if present, nil otherwise
  needs-noweb-no ; content contains <<pattern>>
  needs-comment-no) ; language has no comment syntax

;;;; Scanner

(defun org-babel-entangle--detect-language (filename)
  "Detect org-babel language for FILENAME.
Checks name-based overrides first, then extension-based mapping."
  (let ((base (file-name-nondirectory filename)))
    (or (cdr (assoc base org-babel-entangle-name-language-alist))
        (cdr (assoc (file-name-extension filename t)
                    org-babel-entangle-language-alist)))))

(defun org-babel-entangle--binary-p (filename)
  "Return non-nil if FILENAME appears to be a binary file.
Checks for NUL bytes in the first 8192 bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally filename nil 0 8192)
    (goto-char (point-min))
    (search-forward "\0" nil t)))

(defun org-babel-entangle--excluded-dir-p (dirname)
  "Return non-nil if DIRNAME should be excluded."
  (member (file-name-nondirectory (directory-file-name dirname))
          org-babel-entangle-exclude-directories))

(defun org-babel-entangle--excluded-file-p (filename)
  "Return non-nil if FILENAME should be excluded."
  (member (file-name-nondirectory filename)
          org-babel-entangle-exclude-files))

(defun org-babel-entangle--scan (directory)
  "Scan DIRECTORY and return a list of entry structs.
Skips binary files, excluded directories, and excluded files."
  (let ((root (file-name-as-directory (expand-file-name directory))))
    (org-babel-entangle--scan-recursive root root nil)))

(defun org-babel-entangle--scan-recursive (dir root entries)
  "Recursively scan DIR, accumulating into ENTRIES.
ROOT is the top-level directory for computing relative paths."
  (dolist (file (sort (directory-files dir t nil t) #'string<))
    (let ((basename (file-name-nondirectory file)))
      (cond
       ;; Skip . and ..
       ((member basename '("." "..")) nil)
       ;; Skip excluded directories
       ((and (file-directory-p file)
             (org-babel-entangle--excluded-dir-p file))
        nil)
       ;; Recurse into directories
       ((file-directory-p file)
        (setq entries (org-babel-entangle--scan-recursive file root entries)))
       ;; Skip non-regular files (symlinks, broken links, etc.)
       ((not (file-regular-p file)) nil)
       ;; Skip excluded files
       ((org-babel-entangle--excluded-file-p file) nil)
       ;; Skip binary files
       ((org-babel-entangle--binary-p file) nil)
       ;; Process regular files
       (t
        (let ((lang (org-babel-entangle--detect-language file)))
          (when lang
            (let* ((rel-path (file-relative-name file root))
                   (raw-bytes (with-temp-buffer
                                (set-buffer-multibyte nil)
                                (insert-file-contents-literally file)
                                (buffer-string)))
                   (content (with-temp-buffer
                              (insert-file-contents file)
                              (buffer-string)))
                   (executable-p (file-executable-p file))
                   (shebang (when (string-match "\\`#!.+\n" content)
                              (match-string 0 content)))
                   (needs-noweb-no (string-match-p "<<[a-zA-Z]" content))
                   (needs-comment-no (member lang org-babel-entangle-no-comment-languages)))
              (push (make-org-babel-entangle-entry
                     :path file
                     :rel-path rel-path
                     :content content
                     :raw-bytes raw-bytes
                     :lang lang
                     :executable-p executable-p
                     :shebang shebang
                     :needs-noweb-no needs-noweb-no
                     :needs-comment-no needs-comment-no)
                    entries))))))))
  entries)

;;;; Encoder (fidelity engine)

(defun org-babel-entangle--comma-escape (body)
  "Escape lines in BODY that start with `*' or `#+'.
Org strips the leading comma on tangle, so we add it here."
  (replace-regexp-in-string
   "^\\(\\*\\|#\\+\\)" ",\\1" body))

(defun org-babel-entangle--strip-trailing-newline (s)
  "Remove exactly one trailing newline from S if present.
Org-babel always appends one newline when tangling."
  (if (string-suffix-p "\n" s)
      (substring s 0 -1)
    s))

(defun org-babel-entangle--encode (entry)
  "Produce (BODY-STRING . FIXUPS) for ENTRY.
BODY-STRING is the content to place inside the src block.
FIXUPS is a list of (TYPE . REL-PATH) for post-tangle fixups."
  (let* ((content (org-babel-entangle-entry-content entry))
         (rel-path (org-babel-entangle-entry-rel-path entry))
         (shebang (org-babel-entangle-entry-shebang entry))
         (body content)
         (fixups nil))
    ;; Strip shebang from body — it goes into :shebang header arg
    (when shebang
      (setq body (substring body (length shebang)))
      ;; Detect blank line after shebang (shebang ends with \n,
      ;; so if body starts with \n there was a blank line between)
      (when (string-prefix-p "\n" body)
        (push (cons 'blank-after-shebang rel-path) fixups)))
    ;; Detect trailing newline edge cases before stripping
    (cond
     ;; File ends with \n\n — org will only add one \n
     ((string-suffix-p "\n\n" body)
      (push (cons 'extra-trailing-newline rel-path) fixups))
     ;; File has no trailing \n — org will add one we don't want
     ((and (> (length body) 0)
           (not (string-suffix-p "\n" body)))
      (push (cons 'no-trailing-newline rel-path) fixups)))
    ;; Strip one trailing newline (org adds it back)
    (setq body (org-babel-entangle--strip-trailing-newline body))
    ;; Comma-escape org-special lines
    (setq body (org-babel-entangle--comma-escape body))
    (cons body fixups)))

(defun org-babel-entangle--header-args (entry)
  "Build header-args string for ENTRY's src block."
  (let* ((rel-path (org-babel-entangle-entry-rel-path entry))
         (shebang (org-babel-entangle-entry-shebang entry))
         (needs-noweb-no (org-babel-entangle-entry-needs-noweb-no entry))
         (needs-comment-no (org-babel-entangle-entry-needs-comment-no entry))
         (executable-p (org-babel-entangle-entry-executable-p entry))
         (args (list (format ":tangle %s" rel-path))))
    (when shebang
      (push (format ":shebang \"%s\"" (string-trim-right shebang))
            args))
    (when (and executable-p (not shebang))
      (push ":tangle-mode (identity #o755)" args))
    ;; Comments: per-block to avoid org property resolution issues
    (if needs-comment-no
        (push ":comments no" args)
      (push ":comments link" args))
    (when needs-noweb-no
      (push ":noweb no" args))
    (string-join (nreverse args) " ")))

;;;; Fixup generator

(defun org-babel-entangle--generate-fixups (fixup-list)
  "Generate post-tangle.sh content from FIXUP-LIST.
Each element is (TYPE . REL-PATH)."
  (when fixup-list
    (let ((lines '("#!/usr/bin/env bash"
                   "# Post-tangle fixups for byte-exact fidelity."
                   "# Run from the directory containing the org file."
                   "set -euo pipefail"
                   "cd \"$(dirname \"$0\")\"" "")))
      (dolist (fixup (nreverse fixup-list))
        (let ((type (car fixup))
              (path (cdr fixup)))
          (pcase type
            ('extra-trailing-newline
             (push (format "printf '\\n' >> '%s'" path) lines))
            ('no-trailing-newline
             (push (format "perl -pi -e 'chomp if eof' '%s'" path) lines))
            ('blank-after-shebang
             (push (format "perl -i -pe 'print \"\\n\" if $. == 2' '%s'" path) lines)))))
      (string-join (nreverse lines) "\n"))))

;;;; Layout engine

(defun org-babel-entangle--layout-directory-tree (entries)
  "Organize ENTRIES into a heading tree mirroring the filesystem.
Returns list of (DEPTH HEADING ENTRY-OR-NIL CHILDREN...)
where CHILDREN are nested lists of the same form.
ENTRY is non-nil for leaf nodes (actual files)."
  (let ((dir-table (make-hash-table :test 'equal)))
    ;; Group entries by their directory
    (dolist (entry entries)
      (let* ((rel (org-babel-entangle-entry-rel-path entry))
             (dir (file-name-directory rel)))
        (push entry (gethash (or dir "") dir-table))))
    ;; Build the tree from sorted directory keys
    (let ((dirs (sort (hash-table-keys dir-table) #'string<)))
      (org-babel-entangle--build-tree dirs dir-table))))

(defun org-babel-entangle--build-tree (dirs dir-table)
  "Build heading tree from sorted DIRS and their entries in DIR-TABLE."
  (let (result)
    (dolist (dir dirs)
      (let* ((entries (sort (gethash dir dir-table)
                            (lambda (a b)
                              (string< (org-babel-entangle-entry-rel-path a)
                                       (org-babel-entangle-entry-rel-path b)))))
             (parts (if (string-empty-p dir) nil
                      (split-string (directory-file-name dir) "/")))
             (depth (length parts)))
        ;; Add directory heading(s) if needed
        (when parts
          ;; We'll emit the directory headings as part of the structure
          ;; but let the writer handle depth based on the dir path
          nil)
        ;; Add file entries
        (dolist (entry entries)
          (push (list dir depth entry) result))))
    (nreverse result)))

(defun org-babel-entangle--layout-flat (entries)
  "Organize ENTRIES as a flat list, sorted by relative path."
  (let ((sorted (sort (copy-sequence entries)
                      (lambda (a b)
                        (string< (org-babel-entangle-entry-rel-path a)
                                 (org-babel-entangle-entry-rel-path b))))))
    (mapcar (lambda (entry)
              (list "" 0 entry))
            sorted)))

;;;; Writer

(defun org-babel-entangle--no-comment-languages (entries)
  "Collect the set of no-comment languages actually used in ENTRIES."
  (let (langs)
    (dolist (entry entries)
      (when (org-babel-entangle-entry-needs-comment-no entry)
        (cl-pushnew (org-babel-entangle-entry-lang entry) langs :test #'equal)))
    (sort langs #'string<)))

(defun org-babel-entangle--executable-languages (entries)
  "Collect languages that have executable files in ENTRIES."
  (let (langs)
    (dolist (entry entries)
      (when (or (org-babel-entangle-entry-executable-p entry)
                (org-babel-entangle-entry-shebang entry))
        (cl-pushnew (org-babel-entangle-entry-lang entry) langs :test #'equal)))
    (sort langs #'string<)))

(defun org-babel-entangle--file-header (title _entries)
  "Generate org file header with TITLE.
Comments link/no is handled per-block in header-args, not globally,
because org-babel's property resolution can override per-block args."
  (let ((lines nil))
    ;; File-local variable for auto-tangle
    (when org-babel-entangle-auto-tangle
      (push "# -*- eval: (org-auto-tangle-mode); -*-" lines))
    (push (format "#+TITLE: %s" title) lines)
    (push "#+PROPERTY: header-args :mkdirp yes :padline no" lines)
    (push (format "#+STARTUP: %s" org-babel-entangle-startup) lines)
    (push "" lines)
    (string-join (nreverse lines) "\n")))

(defun org-babel-entangle--format-src-block (entry body)
  "Format a src block for ENTRY with BODY content."
  (let ((lang (org-babel-entangle-entry-lang entry))
        (header-args (org-babel-entangle--header-args entry)))
    (concat (format "#+begin_src %s %s\n" lang header-args)
            body "\n"
            "#+end_src\n")))

(defun org-babel-entangle--write (title entries fixups &optional _config)
  "Assemble org file string from TITLE, ENTRIES, and FIXUPS.
Uses layout strategy from `org-babel-entangle-layout'."
  (let* ((layout-fn (pcase org-babel-entangle-layout
                      ('directory-tree #'org-babel-entangle--layout-directory-tree)
                      ('flat #'org-babel-entangle--layout-flat)
                      (_ #'org-babel-entangle--layout-directory-tree)))
         (layout (funcall layout-fn entries))
         (header (org-babel-entangle--file-header title entries))
         (fixup-script (org-babel-entangle--generate-fixups fixups))
         (body-parts (list header))
         (emitted-dirs (make-hash-table :test 'equal)))
    ;; Build section content
    (dolist (item layout)
      (let* ((dir (nth 0 item))
             (entry (nth 2 item))
             (rel-path (org-babel-entangle-entry-rel-path entry))
             (dir-parts (if (string-empty-p dir) nil
                          (split-string (directory-file-name dir) "/")))
             (filename (file-name-nondirectory rel-path)))
        ;; Emit directory headings we haven't seen yet
        (when (and dir-parts
                   (eq org-babel-entangle-layout 'directory-tree))
          (let ((accum ""))
            (dotimes (i (length dir-parts))
              (setq accum (if (= i 0)
                              (nth i dir-parts)
                            (concat accum "/" (nth i dir-parts))))
              (unless (gethash accum emitted-dirs)
                (puthash accum t emitted-dirs)
                (push (format "%s %s\n"
                              (make-string (1+ i) ?*)
                              (nth i dir-parts))
                      body-parts)))))
        ;; File heading and src block
        (let* ((encode-result (org-babel-entangle--encode entry))
               (body (car encode-result))
               (depth (if (eq org-babel-entangle-layout 'directory-tree)
                          (1+ (length dir-parts))
                        1))
               (stars (make-string depth ?*)))
          (push (format "\n%s %s\n\n%s"
                        stars
                        filename
                        (org-babel-entangle--format-src-block entry body))
                body-parts))))
    ;; Add fixup script section if needed
    (when fixup-script
      (push (format "\n* Build\n\n** post-tangle.sh\n\n#+begin_src bash :tangle post-tangle.sh :tangle-mode (identity #o755)\n%s\n#+end_src\n"
                    fixup-script)
            body-parts))
    (string-join (nreverse body-parts) "")))

;;;; Entry points

;;;###autoload
(defun org-babel-entangle-directory (directory &optional output-file _config)
  "Generate an org file from DIRECTORY that round-trips through `org-babel-tangle'.
OUTPUT-FILE defaults to DIRECTORY/project.org.
When called interactively, prompts for DIRECTORY and OUTPUT-FILE."
  (interactive
   (let* ((dir (read-directory-name "Directory to entangle: "))
          (default-out (expand-file-name "project.org" dir))
          (out (read-file-name "Output org file: " dir default-out nil
                               (file-name-nondirectory default-out))))
     (list dir out)))
  (let* ((dir (file-name-as-directory (expand-file-name directory)))
         (output (or output-file (expand-file-name "project.org" dir)))
         (title (file-name-nondirectory
                 (directory-file-name dir)))
         (entries (org-babel-entangle--scan dir))
         (all-fixups nil))
    (unless entries
      (error "No eligible source files found in %s" dir))
    ;; Collect fixups from all entries
    (dolist (entry entries)
      (let ((encode-result (org-babel-entangle--encode entry)))
        (setq all-fixups (append (cdr encode-result) all-fixups))))
    ;; Reverse fixups to maintain file order
    (setq all-fixups (nreverse all-fixups))
    ;; Generate and write org file
    (let ((org-content (org-babel-entangle--write title entries all-fixups)))
      (with-temp-file output
        (insert org-content))
      (message "Entangled %d files from %s into %s"
               (length entries) dir output)
      output)))

;;;###autoload
(defun org-babel-entangle-batch ()
  "Batch-mode entry point.
Usage: emacs --batch -l org-babel-entangle.el \\
         -f org-babel-entangle-batch /path/to/dir [output.org]"
  (let* ((dir (or (car command-line-args-left)
                  (error "Usage: org-babel-entangle-batch DIR [OUTPUT]")))
         (output (cadr command-line-args-left)))
    (setq command-line-args-left (cddr command-line-args-left))
    (org-babel-entangle-directory dir output)))

(defun org-babel-entangle--strip-comment-links (file)
  "Remove org-babel comment-link markers from FILE in-place.
These are the `# [[file:...]]' and `# ...ends here' lines added
by `:comments link' during tangle."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    ;; Remove "# [[file:...]]" or "// [[file:...]]" or "<!-- [[file:...]] -->" lines
    (while (re-search-forward
            "^[[:blank:]]*\\(?:#\\|//\\|;+\\|%\\|--\\|/\\*\\|<!--\\)[[:blank:]]*\\[\\[file:.*\\]\\].*\n?"
            nil t)
      (replace-match ""))
    (goto-char (point-min))
    ;; Remove "# ...ends here" or "// ...ends here" etc. lines
    (while (re-search-forward
            "^[[:blank:]]*\\(?:#\\|//\\|;+\\|%\\|--\\).*ends here.*\n?"
            nil t)
      (replace-match ""))
    (goto-char (point-min))
    ;; Remove "<!-- ...ends here -->" lines
    (while (re-search-forward
            "^[[:blank:]]*<!--.*ends here.*-->.*\n?"
            nil t)
      (replace-match ""))
    ;; Remove "/* ...ends here */" lines
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:blank:]]*/\\*.*ends here.*\\*/.*\n?"
            nil t)
      (replace-match ""))
    (write-region (point-min) (point-max) file nil 'silent)))

;;;###autoload
(defun org-babel-entangle-verify (org-file source-dir)
  "Tangle ORG-FILE into a temp dir, run fixups, diff against SOURCE-DIR.
Strips comment-link markers before comparing, since those are expected
additions from `:comments link'.
Returns nil if identical, or a list of differing files.
When called interactively, reports results in *Messages*."
  (interactive
   (list (read-file-name "Org file to verify: ")
         (read-directory-name "Source directory: ")))
  (let* ((org-file (expand-file-name org-file))
         (source-dir (file-name-as-directory (expand-file-name source-dir)))
         (tmp-dir (make-temp-file "entangle-verify-" t))
         (default-directory tmp-dir)
         (diffs nil))
    (unwind-protect
        (progn
          ;; Copy org file to temp dir
          (copy-file org-file (expand-file-name (file-name-nondirectory org-file) tmp-dir) t)
          (let ((tmp-org (expand-file-name (file-name-nondirectory org-file) tmp-dir)))
            ;; Tangle
            (with-current-buffer (find-file-noselect tmp-org)
              (org-babel-tangle)
              (kill-buffer))
            ;; Run post-tangle.sh if it was generated
            (let ((fixup-script (expand-file-name "post-tangle.sh" tmp-dir)))
              (when (file-exists-p fixup-script)
                (shell-command (format "bash '%s'" fixup-script))))
            ;; Strip comment-link markers from tangled files and diff
            (let ((entries (org-babel-entangle--scan source-dir)))
              (dolist (entry entries)
                (let* ((rel (org-babel-entangle-entry-rel-path entry))
                       (orig (expand-file-name rel source-dir))
                       (tangled (expand-file-name rel tmp-dir)))
                  (cond
                   ((not (file-exists-p tangled))
                    (push (format "MISSING: %s" rel) diffs))
                   (t
                    ;; Strip comment-link markers before comparing
                    (unless (org-babel-entangle-entry-needs-comment-no entry)
                      (org-babel-entangle--strip-comment-links tangled))
                    (unless (zerop (call-process "diff" nil nil nil
                                                 "-q" orig tangled))
                      (push (format "DIFFERS: %s" rel) diffs)))))))))
      ;; Cleanup
      (delete-directory tmp-dir t))
    (when (called-interactively-p 'any)
      (if diffs
          (message "Verification FAILED:\n%s" (string-join diffs "\n"))
        (message "Verification PASSED: all files match.")))
    diffs))

(provide 'org-babel-entangle)
;;; org-babel-entangle.el ends here
