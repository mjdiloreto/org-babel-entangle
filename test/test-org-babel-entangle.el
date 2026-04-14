;;; test-org-babel-entangle.el --- Tests for org-babel-entangle -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the org-babel-entangle package.

;;; Code:

(require 'ert)
(require 'org-babel-entangle)

;;;; Language detection tests

(ert-deftest entangle-test-detect-lang-by-extension ()
  "Language detection works for known extensions."
  (should (equal "python" (org-babel-entangle--detect-language "foo.py")))
  (should (equal "js" (org-babel-entangle--detect-language "app.js")))
  (should (equal "emacs-lisp" (org-babel-entangle--detect-language "init.el")))
  (should (equal "bash" (org-babel-entangle--detect-language "run.sh")))
  (should (equal "json" (org-babel-entangle--detect-language "data.json")))
  (should (equal "yaml" (org-babel-entangle--detect-language "config.yml"))))

(ert-deftest entangle-test-detect-lang-by-name ()
  "Language detection works for known filenames."
  (should (equal "makefile" (org-babel-entangle--detect-language "Makefile")))
  (should (equal "dockerfile" (org-babel-entangle--detect-language "Dockerfile")))
  (should (equal "ruby" (org-babel-entangle--detect-language "Gemfile"))))

(ert-deftest entangle-test-detect-lang-unknown ()
  "Unknown extensions return nil."
  (should-not (org-babel-entangle--detect-language "README"))
  (should-not (org-babel-entangle--detect-language "data.xyz")))

;;;; Comma-escape tests

(ert-deftest entangle-test-comma-escape-star ()
  "Lines starting with * get comma-escaped."
  (should (equal ",* heading" (org-babel-entangle--comma-escape "* heading")))
  (should (equal ",** sub" (org-babel-entangle--comma-escape "** sub"))))

(ert-deftest entangle-test-comma-escape-hash-plus ()
  "Lines starting with #+ get comma-escaped."
  (should (equal ",#+BEGIN_SRC" (org-babel-entangle--comma-escape "#+BEGIN_SRC")))
  (should (equal ",#+TITLE: foo" (org-babel-entangle--comma-escape "#+TITLE: foo"))))

(ert-deftest entangle-test-comma-escape-normal ()
  "Normal lines are not escaped."
  (should (equal "hello world" (org-babel-entangle--comma-escape "hello world")))
  (should (equal "# comment" (org-babel-entangle--comma-escape "# comment"))))

(ert-deftest entangle-test-comma-escape-multiline ()
  "Multi-line content has each matching line escaped."
  (let ((input "line 1\n* heading\nline 3\n#+PROP"))
    (should (equal "line 1\n,* heading\nline 3\n,#+PROP"
                   (org-babel-entangle--comma-escape input)))))

;;;; Trailing newline tests

(ert-deftest entangle-test-strip-trailing-newline ()
  "Strips exactly one trailing newline."
  (should (equal "foo" (org-babel-entangle--strip-trailing-newline "foo\n")))
  (should (equal "foo\n" (org-babel-entangle--strip-trailing-newline "foo\n\n")))
  (should (equal "foo" (org-babel-entangle--strip-trailing-newline "foo"))))

;;;; Encoder tests

(ert-deftest entangle-test-encode-simple ()
  "Simple file encoding strips trailing newline."
  (let* ((entry (make-org-babel-entangle-entry
                 :path "/tmp/test.py"
                 :rel-path "test.py"
                 :content "print('hello')\n"
                 :raw-bytes "print('hello')\n"
                 :lang "python"
                 :executable-p nil
                 :shebang nil
                 :needs-noweb-no nil
                 :needs-comment-no nil))
         (result (org-babel-entangle--encode entry)))
    (should (equal "print('hello')" (car result)))
    (should (null (cdr result)))))

(ert-deftest entangle-test-encode-shebang ()
  "Shebang is stripped from body."
  (let* ((entry (make-org-babel-entangle-entry
                 :path "/tmp/run.sh"
                 :rel-path "run.sh"
                 :content "#!/bin/bash\necho hi\n"
                 :raw-bytes "#!/bin/bash\necho hi\n"
                 :lang "bash"
                 :executable-p t
                 :shebang "#!/bin/bash\n"
                 :needs-noweb-no nil
                 :needs-comment-no nil))
         (result (org-babel-entangle--encode entry)))
    (should (equal "echo hi" (car result)))
    (should (null (cdr result)))))

(ert-deftest entangle-test-encode-noweb-content ()
  "Content with << gets :noweb no in header args."
  (let* ((entry (make-org-babel-entangle-entry
                 :path "/tmp/tmpl.py"
                 :rel-path "tmpl.py"
                 :content "x = <<value>>\n"
                 :raw-bytes "x = <<value>>\n"
                 :lang "python"
                 :executable-p nil
                 :shebang nil
                 :needs-noweb-no t
                 :needs-comment-no nil))
         (args (org-babel-entangle--header-args entry)))
    (should (string-match-p ":noweb no" args))))

(ert-deftest entangle-test-encode-no-trailing-newline ()
  "File without trailing newline produces fixup."
  (let* ((entry (make-org-babel-entangle-entry
                 :path "/tmp/test.py"
                 :rel-path "test.py"
                 :content "print('hello')"
                 :raw-bytes "print('hello')"
                 :lang "python"
                 :executable-p nil
                 :shebang nil
                 :needs-noweb-no nil
                 :needs-comment-no nil))
         (result (org-babel-entangle--encode entry))
         (fixups (cdr result)))
    (should (= 1 (length fixups)))
    (should (eq 'no-trailing-newline (caar fixups)))))

(ert-deftest entangle-test-encode-extra-trailing-newline ()
  "File ending with double newline produces fixup."
  (let* ((entry (make-org-babel-entangle-entry
                 :path "/tmp/test.py"
                 :rel-path "test.py"
                 :content "print('hello')\n\n"
                 :raw-bytes "print('hello')\n\n"
                 :lang "python"
                 :executable-p nil
                 :shebang nil
                 :needs-noweb-no nil
                 :needs-comment-no nil))
         (result (org-babel-entangle--encode entry))
         (fixups (cdr result)))
    (should (= 1 (length fixups)))
    (should (eq 'extra-trailing-newlines (caar fixups)))))

;;;; Header args tests

(ert-deftest entangle-test-header-args-simple ()
  "Simple file gets just :tangle."
  (let* ((entry (make-org-babel-entangle-entry
                 :path "/tmp/test.py"
                 :rel-path "src/test.py"
                 :content ""
                 :raw-bytes ""
                 :lang "python"
                 :executable-p nil
                 :shebang nil
                 :needs-noweb-no nil
                 :needs-comment-no nil))
         (args (org-babel-entangle--header-args entry)))
    (should (equal ":tangle src/test.py :comments link" args))))

(ert-deftest entangle-test-header-args-json ()
  "JSON gets :comments no."
  (let* ((entry (make-org-babel-entangle-entry
                 :path "/tmp/data.json"
                 :rel-path "data.json"
                 :content ""
                 :raw-bytes ""
                 :lang "json"
                 :executable-p nil
                 :shebang nil
                 :needs-noweb-no nil
                 :needs-comment-no t))
         (args (org-babel-entangle--header-args entry)))
    (should (string-match-p ":comments no" args))))

(ert-deftest entangle-test-header-args-executable ()
  "Executable file without shebang gets :tangle-mode."
  (let* ((entry (make-org-babel-entangle-entry
                 :path "/tmp/run.py"
                 :rel-path "run.py"
                 :content ""
                 :raw-bytes ""
                 :lang "python"
                 :executable-p t
                 :shebang nil
                 :needs-noweb-no nil
                 :needs-comment-no nil))
         (args (org-babel-entangle--header-args entry)))
    (should (string-match-p ":tangle-mode" args))))

;;;; Comment-link detection tests

(ert-deftest entangle-test-comment-link-allowlist ()
  "Languages in the allowlist get comment-link support."
  (should (org-babel-entangle--lang-supports-comments-p "python"))
  (should (org-babel-entangle--lang-supports-comments-p "emacs-lisp"))
  (should (org-babel-entangle--lang-supports-comments-p "bash")))

(ert-deftest entangle-test-comment-link-not-in-allowlist ()
  "Languages not in the allowlist get :comments no by default."
  (let ((org-babel-entangle-auto-detect-comments nil))
    (should-not (org-babel-entangle--lang-supports-comments-p "json"))
    (should-not (org-babel-entangle--lang-supports-comments-p "yaml"))
    (should-not (org-babel-entangle--lang-supports-comments-p "forth"))))

(ert-deftest entangle-test-comment-link-auto-detect ()
  "Auto-detect finds comment-start in emacs-lisp-mode for unlisted lang."
  (let ((org-babel-entangle-comment-link-languages nil)
        (org-babel-entangle-auto-detect-comments t))
    ;; emacs-lisp-mode always available, defines comment-start
    (should (org-babel-entangle--lang-supports-comments-p "emacs-lisp"))))

;;;; Scanner integration test (uses temp directory)

(ert-deftest entangle-test-scan-temp-dir ()
  "Scanner finds files and detects properties correctly."
  (let ((tmp (make-temp-file "entangle-test-" t)))
    (unwind-protect
        (progn
          ;; Create test files
          (with-temp-file (expand-file-name "hello.py" tmp)
            (insert "#!/usr/bin/env python3\nprint('hello')\n"))
          (with-temp-file (expand-file-name "data.json" tmp)
            (insert "{\"key\": \"value\"}\n"))
          (with-temp-file (expand-file-name "config.yaml" tmp)
            (insert "key: value\n"))
          ;; Make the python file executable
          (set-file-modes (expand-file-name "hello.py" tmp) #o755)
          ;; Scan
          (let ((entries (org-babel-entangle--scan tmp)))
            ;; Should find 3 files
            (should (= 3 (length entries)))
            ;; Check languages
            (let ((langs (sort (mapcar #'org-babel-entangle-entry-lang entries)
                               #'string<)))
              (should (equal '("json" "python" "yaml") langs)))
            ;; Check shebang detection
            (let ((py-entry (cl-find "python" entries
                                     :key #'org-babel-entangle-entry-lang
                                     :test #'equal)))
              (should (org-babel-entangle-entry-shebang py-entry))
              (should (org-babel-entangle-entry-executable-p py-entry)))
            ;; Check JSON gets no-comment flag
            (let ((json-entry (cl-find "json" entries
                                       :key #'org-babel-entangle-entry-lang
                                       :test #'equal)))
              (should (org-babel-entangle-entry-needs-comment-no json-entry)))))
      (delete-directory tmp t))))

;;;; End-to-end test

(ert-deftest entangle-test-end-to-end ()
  "Full round-trip: scan -> encode -> write produces valid org."
  (let ((tmp (make-temp-file "entangle-e2e-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "main.py" tmp)
            (insert "print('hello')\n"))
          (with-temp-file (expand-file-name "config.yaml" tmp)
            (insert "key: value\n"))
          (let* ((entries (org-babel-entangle--scan tmp))
                 (encoded-entries nil)
                 (all-fixups nil))
            (dolist (entry entries)
              (let ((result (org-babel-entangle--encode entry)))
                (push (cons entry (car result)) encoded-entries)
                (setq all-fixups (append (cdr result) all-fixups))))
            (setq encoded-entries (nreverse encoded-entries))
            (let ((org-content (org-babel-entangle--write "test-project" encoded-entries all-fixups)))
              ;; Should contain expected structure
              (should (string-match-p "#\\+TITLE: test-project" org-content))
              (should (string-match-p ":PROPERTIES:" org-content))
              (should (string-match-p ":header-args:python:" org-content))
              (should (string-match-p ":comments link" org-content))
              (should (string-match-p "begin_src python" org-content))
              (should (string-match-p "begin_src yaml" org-content))
              (should (string-match-p ":tangle main\\.py" org-content))
              (should (string-match-p ":tangle config\\.yaml" org-content)))))
      (delete-directory tmp t))))

;;;; Minor mode tests

(ert-deftest entangle-test-minor-mode-toggle ()
  "Minor mode adds and removes advice on `org-babel-tangle'."
  ;; Ensure mode is off
  (org-babel-entangle-mode -1)
  (should-not (advice-member-p #'org-babel-entangle--after-tangle 'org-babel-tangle))
  ;; Turn on
  (org-babel-entangle-mode 1)
  (should (advice-member-p #'org-babel-entangle--after-tangle 'org-babel-tangle))
  ;; Turn off
  (org-babel-entangle-mode -1)
  (should-not (advice-member-p #'org-babel-entangle--after-tangle 'org-babel-tangle)))

;;;; After-directory hook tests

(ert-deftest entangle-test-after-directory-hook ()
  "Hook runs after `org-babel-entangle-directory' with output file bound."
  (let ((tmp (make-temp-file "entangle-hook-" t))
        (captured-file nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "main.py" tmp)
            (insert "print('hello')\n"))
          (let ((org-babel-entangle-after-directory-hook
                 (list (lambda () (setq captured-file org-babel-entangle-output-file)))))
            (org-babel-entangle-directory tmp)
            (should captured-file)
            (should (string-match-p "project\\.org$" captured-file))
            (should (file-exists-p captured-file))))
      (delete-directory tmp t))))

(provide 'test-org-babel-entangle)
;;; test-org-babel-entangle.el ends here
