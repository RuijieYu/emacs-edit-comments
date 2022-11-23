;;; edit-comments.el --- Edit blocks of comments in a separate buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2022-2022 Ruijie Yu
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied
;; warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
;; PURPOSE. See the GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public
;; License along with this program. If not, see
;; <https://www.gnu.org/licenses/>.

;;; Author: Ruijie Yu <ruijie@netyu.xyz>
;;; Created: 22 Nov 2022

;;; Homepage: https://github.com/RuijieYu/emacs-edit-comments
;;; Keywords: tools, wp

;;; Version: 0.1.0-git
;;; Package-Requires: ((emacs "26.1"))

;;; Commentary:

;; This package adds an analogous command of `org-edit-src-code'
;; that is suitable for all major modes.  For more details, see
;; the README file.
;;
;; Entry points of this package are `edit-comments-mode',
;; `global-edit-comments-mode', and `edit-comments-start'.

;;; Code:


;;; Dependencies
(require 'cl-lib)                      ; implied by (emacs > 24.3)


;;; Customizable Variables
(defgroup edit-comments nil
  "Edit a comment block in its dedicated buffer."
  :tag "Edit Comments"
  :group 'comment
  :group 'convenience
  :group 'text)

;;;###autoload
(defcustom edit-comments-window-setup 'reorganize-frame
  "How the comment buffer should be displayed.

Analogous to `org-src-window-setup'."
  :group 'edit-comments
  :type '(choice (const plain)
                 (const current-window)
                 (const split-window-below)
                 (const split-window-right)
                 (const other-frame)
                 (const other-window)
                 (const reorganize-frame)))


;;; Public Variables
;;;###autoload
(defconst edit-comments-default-major-mode
  #'text-mode)

;;;###autoload
(defvar edit-comments-major-modes
  `((rust-mode . markdown-mode)
    ;; default
    (t . ,edit-comments-default-major-mode))
  "A list of major mode specifications.

Each element of the list is a `cons' cell (PARENT-MAJ-MODE
. COMMENT-MAJ-MODE) or a plist (:parent PARENT-MAJ-MODE :comment
COMMENT-MAJ-MODE :requires REQUIRES :opt-requires OPT-REQUIRES
:post-init POST-INIT), where PARENT-MAJ-MODE should be either a
major mode function or t, and COMMENT-MAJ-MODE should be a
function or nil.  The REQUIRES list and OPT-REQUIRES, if
specified, are the list of packages to hard-, and soft-`require'
before calling COMMENT-MAJ-MODE, respectively.  The POST-INIT, if
non-nil, is a function to call just after switching the major
modes and flushing the undo information.

Upon creation of a inferior buffer, the first cell whose key
matches PARENT-MAJ-MODE (using `derived-mode-p') or is t will be
selected.  When one such cell is selected, then the
COMMENT-MAJ-MODE major mode function is called, where `text-mode'
is used by default if nil.")


;;; Macros
(defmacro edit-comments-with-parent-buffer (inf-buf &rest body)
  "Execute BODY in the parent buffer of INF-BUF."
  (declare (indent 1))
  `(with-current-buffer ,inf-buf
     (let ((overlay (edit-comments--get 'overlay)))
       (and overlay (with-current-buffer (overlay-buffer overlay)
                      ,@body)))))


;;; Entry points
;;;###autoload
(defun edit-comments-start (&optional point arg)
  "Start editing a comment block.

ARG is the raw prefix argument (see `interactive').  When nil (no
prefix), find the comment region around POINT.  When any prefix,
do not go beyond newline-delimited comment blocks."
  (interactive "i\nP")
  (edit-comments--edit-element (or point (point)) nil arg))

;;;###autoload
(define-minor-mode edit-comments-mode
  "Minor mode to allow editing comments in a separate buffer.

\\{edit-comments-mode-map}"
  :lighter " EdCmt"
  :keymap '(([?\C-c ?\'] . edit-comments-start))
  :group 'edit-comments)

;;;###autoload
(define-minor-mode edit-comments-inferior-mode
  "This minor mode is enabled for inferior buffers.

See also `edit-comment-mode' and `edit-comments-start'.

\\{edit-comments-inferior-mode-map}"
  :lighter " EdCmtInf"
  :interactive nil
  :keymap '(([remap save-buffer] . edit-comments-save-buffer)
            ([?\C-c ?'] . edit-comments-exit)
            ([?\C-c ?\C-k] . edit-comments-abort))
  (cond
   (edit-comments-inferior-mode
    (add-hook
     'kill-buffer-hook #'edit-comments--kill-hook nil t)
    (setq-local
     header-line-format
     (substitute-command-keys
      "Edit, then exit with `\\[edit-comments-exit]' \
or abort with `\\[edit-comments-abort]'")))
   (t
    (remove-hook
     'kill-buffer-hook #'edit-comments--kill-hook t)
    (setq-local header-line-format nil))))

;;;###autoload
(define-globalized-minor-mode global-edit-comments-mode
  edit-comments-mode (lambda ()
                       (unless edit-comments-inferior-mode
                         (edit-comments-mode 1)))
  :group 'edit-comments)


;;; Store related variables and functions
(defvar-local edit-comments--inferior-store (make-hash-table)
  "The value store for an inferior buffer.

This is used by various internal components of
`edit-comments-inferior-mode'.

Currently the following keys (as symbols) are defined: (1) begin:
the beginning of parent comment block; (2) end: the end of parent
comment block; (3) overlay: the overlay in effect in the parent
comment block; (4) comment: the stored comment style (used by the
first non-empty comment line).")

(defun edit-comments--get (key &optional default)
  "Get KEY from hash table `edit-comments--inferior-store'.

The optional DEFAULT is the default value."
  (gethash key edit-comments--inferior-store default))

(defun edit-comments--put (&rest args)
  "Put each pair into `edit-comments--inferior-store'.

ARGS should be repeated KEY VALUE pairs.

\(fn [KEY VALUE]...)"
  (cl-do ((len (length args))
          (args args (cddr args)))
      ((length< args 2)
       (when args
         (signal 'wrong-number-of-arguments `((% X 2) ,len))))
    (puthash (nth 0 args) (nth 1 args)
             edit-comments--inferior-store)))


;;; Internal functions and variables
(defvar edit-comments--saved-temp-window-config nil
  "Saved window layout.")

(defun edit-comments--comment-begin (&optional point arg)
  ;; Ref: https://emacs.stackexchange.com/a/21835
  "Find the beginning of the current comment around POINT.

Return nil if not inside a comment.  This function finds the
*first* comment if inside a series of line comments.

When ARG is (4) (a single \\[universal-argument]), do not
backtrack beyond empty lines (without comment prefixes).  That
is, the following should find the beginning of the third line:

>>>
;; comment line 1

;; comment| line 3
<<<

Caveats: (1) this function recognizes the position before a
comment begins: \"|//\"; (2) this function recognizes the
position immediately after a comment *only if* there is a space,
tab or newline character after it: \"// string|\\n\"."
  (save-excursion
    ;; `1+' because we might be at "|//" position, so move forward
    ;; to at least partially scan the comment syntax
    (goto-char (1+ (or point (point))))
    (cl-flet ((skip-back nil
                (skip-chars-backward
                 "\t\n " (and arg (1- (line-beginning-position))))
                nil))
      (cl-do ((start
               (skip-back)
               (let ((syntax (syntax-ppss)))
                 (cond
                  ;; When ARG non-nil, stop if current line
                  ;; only contains empty characters.
                  ((pcase arg
                     ('(4) (edit-comments--empty-line-p))
                     (_ nil))
                   (cl-return start))
                  ;; [4] is whether we are *inside* a comment;
                  ;; [8] is the beginning of this comment
                  ((nth 4 syntax) (goto-char (nth 8 syntax)))
                  ;; [10] is whether we have incomplete
                  ;; parsings, move forward and parse again
                  ((nth 10 syntax)
                   (forward-char) start)
                  (t (cl-return start))))))
          ((skip-back))))))

(defun edit-comments--comment-end (&optional point arg)
  ;; Ref: https://emacs.stackexchange.com/a/21835
  "Find the end of the current comment at POINT.

When ARG is non-nil, do not step beyond fully empty lines.

Return nil if not inside a comment.  This function finds the
*last* comment if inside a series of line comments."
  (save-excursion
    (when point (goto-char point))
    (let ((begin (nth 8 (syntax-ppss))))
      ;; go to beginning of current comment, otherwise
      ;; `forward-comment' wouldn't work correctly
      (when begin (goto-char begin))
      (pcase arg
        ('(4) (while (not (edit-comments--empty-line-p))
                (forward-comment 1)))
        (_ (forward-comment (buffer-size))))
      (point))))

(defun edit-comments--contents-area (&optional point arg)
  "Return the comment boundaries of POINT.

ARG is passed from `edit-comments-start', which see.

Return a list (BEGIN END CONTENTS) where BEGIN and END are buffer
positions and CONTENTS is the contents of the region."
  (let* ((point (or point (point)))
         (begin (edit-comments--comment-begin point arg))
         (end (edit-comments--comment-end point arg)))
    (list (copy-marker begin t)
          (copy-marker end t)
          (buffer-substring-no-properties begin end))))

(defun edit-comments--old-edit-buffer (&optional begin end)
  ;; Ref: `org-src--edit-buffer'
  "Recall a previous edit buffer for the BEGIN END pair.

Return nil otherwise."
  ;; `equal' equates two marks ignoring the "move after insertion"
  ;; flag, which is desired
  (let* ((use-params (and begin end))
         (begin (if use-params begin
                  (edit-comments--comment-begin)))
         (end (if use-params end
                (edit-comments--comment-end))))
    (cl-dolist (b (buffer-list))
      (with-current-buffer b
        (and edit-comments-inferior-mode
             (equal begin (edit-comments--get 'begin))
             (equal end (edit-comments--get 'end))
             (cl-return b))))))

(defun edit-comments--make-source-overlay (begin end inf-buf)
  "Generate and return an overlay for INF-BUF.

The overlay should indicate that the region (BEGIN END) is being
edited in the dedicated buffer INF-BUF."
  (let ((overlay (make-overlay begin end)))
    (cl-flet ((oput (prop val) (overlay-put overlay prop val))
              (oget (prop) (overlay-get overlay prop)))
      ;; standard properties
      (oput 'face 'secondary-selection)
      (oput
       'help-echo
       "Click with mouse-1 to switch to its inferior buffer")
      (oput 'edit-comments-inferior-buffer inf-buf)
      (oput 'keymap
            (let ((map (make-sparse-keymap)))
              (define-key map [mouse-1] #'edit-comments-continue)
              map))
      (let ((read-only
             (list
              (lambda (&rest _)
                (user-error
                 "Cannot modify a controlled buffer")))))
        (oput 'modification-hooks read-only)
        (oput 'insert-in-front-hooks read-only)
        (oput 'insert-behind-hooks read-only)
        overlay))))

(defun edit-comments--edit-element
    (point &optional initialize arg)
  "Edit the comments around POINT in a separate buffer.

ARG is passed from `edit-comments-start', which see.

Return the created buffer.  If INITIALIZE is non-nil, it should
be a function accepting no arguments, called after the buffer is
just initialize."
  (interactive (list (point)))
  (when (memq edit-comments-window-setup '(reorganize-frame
                                           split-window-below
                                           split-window-right))
    (setq edit-comments--saved-temp-window-config
          (current-window-configuration)))
  (let* ((area (edit-comments--contents-area point arg))
         (begin (nth 0 area))
         (end (nth 1 area))
         (contents (nth 2 area))
         (old-buffer (edit-comments--old-edit-buffer begin end)))
    (if old-buffer (edit-comments-switch-to-buffer
                    old-buffer 'return)
      (let* ((buf-name (buffer-name (buffer-base-buffer)))
             (inf-buf (generate-new-buffer
                       (format "*edit-comments*[%s]" buf-name)))
             (overlay (edit-comments--make-source-overlay
                       begin end inf-buf)))
        ;; switch to edit buffer
        (edit-comments-switch-to-buffer inf-buf 'edit)
        ;; insert contents
        (insert contents)
        (remove-text-properties
         (point-min) (point-max)
         '(display nil invisible nil intangible nil))
        (set-buffer-modified-p nil)
        (setq buffer-file-name nil)
        ;; init buffer
        (when initialize
          (condition-case e (funcall initialize)
            (error (message "Initialization fails with: %s"
                            (error-message-string e)))))
        ;; prepare contents
        (with-current-buffer inf-buf
          (edit-comments--put
           'overlay overlay 'begin begin 'end end))
        (edit-comments--strip-comments inf-buf)
        ;; start major mode and minor mode
        (edit-comments-choose-major-mode inf-buf)
        (edit-comments-inferior-mode)
        ;; flush undo states
        (buffer-disable-undo)
        (buffer-enable-undo)))))

(defun edit-comments-choose-major-mode (inf-buf)
  "Set the major mode and perform setup for INF-BUF.

Consult `edit-comments-major-modes' for how to set up the buffer.
Save and restore the value of `edit-comments--inferior-store'
after switching the major mode and before POST-INIT is called."
  (interactive (list (current-buffer)))
  (with-current-buffer inf-buf
    (cl-do ((specs edit-comments-major-modes (cdr specs)))
        ((null specs)
         (edit-comments-set-major-mode
          (list :comment edit-comments-default-major-mode)))
      (let* ((spec (car specs))
             ;; `plistp' doesn't exist for emacs < 29
             (plistp (and spec (listp spec) (keywordp (car spec))))
             (parent-maj-mode
              (if plistp (plist-get spec :parent)
                (car spec))))
        (when (or (eql t parent-maj-mode)
                  (edit-comments-with-parent-buffer inf-buf
                    (derived-mode-p parent-maj-mode)))
          (edit-comments-set-major-mode
           (if plistp spec
             (list :parent (car spec) :comment (cdr spec))))
          (cl-return))))))

(defun edit-comments-set-major-mode (plist)
  "Use PLIST to set the major mode for the current inferior buffer.

See `edit-comments-choose-major-mode' and
`edit-comments-major-modes'."
  (let* ((inf-maj-mode (plist-get plist :comment))
         (reqs (plist-get plist :requires))
         (opts (plist-get plist :opt-requires))
         (post-init (plist-get plist :post-init)))
    ;; Requires
    (dolist (req reqs) (require req))
    (dolist (opt opts) (require opt nil 'no-error))
    ;; Convert the inferior buffer to the specified major mode,
    ;; while preserving the value store
    (let ((store edit-comments--inferior-store))
      (funcall inf-maj-mode)
      (setq-local edit-comments--inferior-store store))
    ;; Perform post-init
    (when (functionp post-init)
      (funcall post-init))))

(defun edit-comments--writeback-prepare (writeback-buf)
  "Prepare the write-back buffer WRITEBACK-BUF.

This assumes that point is in the edit buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((inf-buf (current-buffer))
          (skipped (edit-comments--get 'comment)))
      (while (not (eobp))
        (let ((begin (line-beginning-position))
              (end (line-end-position)))
          (unless skipped (error "Comment was not stripped"))
          (with-current-buffer writeback-buf
            (insert skipped)
            (insert-buffer-substring-no-properties
             inf-buf begin end)
            (insert-char ?\C-j)))
        (forward-line)))))

(defun edit-comments--restore-overlay (inf-buf)
  "Delete the overlay in the parent buffer of INF-BUF."
  (with-current-buffer inf-buf
    (let ((overlay (edit-comments--get 'overlay)))
      (and (overlayp overlay)
           (delete-overlay overlay)
           (edit-comments--put 'overlay nil)))))


;;; Inferior buffer functions
(defun edit-comments-continue (event)
  ;; Ref: `org-edit-src-continue'
  "Go to the edit buffer under point.

EVENT is used to take in the mouse event.  Error if no inferior
buffer exists for the context."
  (interactive "e")
  (mouse-set-point event)
  (let ((buf (get-char-property
              (point) 'edit-comments-inferior-buffer)))
    (if buf (edit-comments-switch-to-buffer buf 'continue)
      (user-error "No sub-editing buffer for area at point"))))

(defun edit-comments-abort ()
  "Abort editing the comment block."
  (interactive)
  (unless edit-comments-inferior-mode
    (user-error "Not in a sub-editing buffer"))
  (kill-buffer (current-buffer))
  (when edit-comments--saved-temp-window-config
    (unwind-protect
        (set-window-configuration
         edit-comments--saved-temp-window-config))
    (setq edit-comments--saved-temp-window-config nil)))

(defun edit-comments-exit ()
  "Finish editing the comment block."
  (interactive)
  (unless edit-comments-inferior-mode
    (user-error "Not in a sub-editing buffer"))
  (edit-comments-save-buffer 'no-save)
  (edit-comments-abort))

(defun edit-comments--kill-hook ()
  "Hook run before killing an inferior buffer."
  (edit-comments--restore-overlay (current-buffer)))

(defun edit-comments--strip-comments (inf-buf)
  "Strip the comment in INF-BUF taken from its parent buffer.

TODO: currently we assume all comments are of the same style.
This is not true for all programming languages."
  ;; At the moment, each line should start with some indentation,
  ;; then the comment-start string, then optionally a space.
  ;;
  ;; Example:
  ;;
  ;;     /// Docstring here.
  (with-current-buffer inf-buf
    (save-excursion
      (edit-comments--ensure-ending-newline)
      ;; Remove leading empty lines
      (indent-region (point-min) (point-max)
                     (current-left-margin))
      ;; All lines now properly left-aligned, assuming a series of
      ;; line comments of the *same* style.  Try to strip first
      ;; line, and assume that all subsequent lines are either
      ;; empty or have the same line comment style.
      (goto-char (point-min))
      (save-match-data
        (let ((comment-start-skip
               (edit-comments-with-parent-buffer (current-buffer)
                 comment-start-skip))
              (skipped nil))
          (while (eobp)
            (beginning-of-line)
            ;; Try to match current line with parent comment regex
            (let* ((line (buffer-substring
                          (line-beginning-position)
                          (line-end-position))))
              (if (string-match comment-start-skip line)
                  ;; When a match, save comment start if not
                  ;; already saved; then strip the start
                  (progn
                    ;; save conditionally
                    (unless skipped
                      (let ((comment (match-string-no-properties
                                      0 line)))
                        (setq skipped
                              (if (string-match-p
                                   (rx space line-end) comment)
                                  comment (concat comment " ")))))
                    ;; then strip comment
                    (delete-char
                     (- (match-end 0) (match-beginning 0))))
                ;; When not a match, delete the line
                (edit-comments--kill-current-line))
              (forward-line)))
          (edit-comments--put 'comment skipped))))))

(defun edit-comments-save-buffer (&optional no-save)
  "Modify and save the parent buffer according to inferior buffer.

This command is run inside the inferior buffer.

Do not actually save the parent buffer (but still modify it) if
NO-SAVE is non-nil."
  (interactive)
  (and edit-comments-inferior-mode
       (let* ((writeback-buf (generate-new-buffer "*ec-write*"))
              (begin (edit-comments--get 'begin))
              (end (edit-comments--get 'end))
              (overlay (edit-comments--get 'overlay))
              (parent-buf (marker-buffer begin))
              (inf-buf (current-buffer)))
         (run-hooks 'before-save-hook)
         (with-current-buffer inf-buf
           (edit-comments--ensure-ending-newline)
           (set-buffer-modified-p nil)
           (edit-comments--writeback-prepare writeback-buf)
           (with-current-buffer parent-buf
             (undo-boundary)
             (goto-char begin)
             ;; temporarily disable the read only overlay
             (delete-overlay overlay)
             (let ((expecting-bol (bolp)))
               (save-restriction
                 (narrow-to-region begin end)
                 (replace-buffer-contents writeback-buf 0.1 nil)
                 (goto-char (point-max)))
               (when (and expecting-bol (not (bolp)))
                 (insert "\n"))
               (indent-region begin (min (1+ end) (point-max))))
             (kill-buffer writeback-buf)
             (unless no-save (save-buffer))
             (move-overlay overlay begin (point))))
         ;; (message "%s" )
         (run-hooks 'after-save-hook)))
  t)

(defun edit-comments-switch-to-buffer (buf context)
  ;; Ref: `org-src-switch-to-buffer'
  "Switch to BUF.

This consults CONTEXT and `edit-comments-window-setup'."
  (pcase edit-comments-window-setup
    (`plain
     (when (eq context 'exit) (quit-restore-window))
     (pop-to-buffer buf))
    (`current-window (pop-to-buffer-same-window buf))
    (`other-window
     ;; Refs: `org-no-popups', `org-switch-to-buffer-other-window'
     (let ((cur-win (selected-window)))
       (edit-comments--switch-to-buffer-other-window buf)
       (when (eq context 'exit) (quit-restore-window cur-win))))
    (`split-window-below
     (if (eq context 'exit)
         (delete-window)
       (select-window (split-window-vertically)))
     (pop-to-buffer-same-window buf))
    (`split-window-right
     (if (eq context 'exit)
         (delete-window)
       (select-window (split-window-horizontally)))
     (pop-to-buffer-same-window buf))
    (`other-frame
     (pcase context
       (`exit
        (let ((frame (selected-frame)))
          (switch-to-buffer-other-frame buf)
          (delete-frame frame)))
       (`save
        (kill-buffer (current-buffer))
        (pop-to-buffer-same-window buf))
       (_ (switch-to-buffer-other-frame buf))))
    (`reorganize-frame
     (when (eq context 'edit) (delete-other-windows))
     (edit-comments--switch-to-buffer-other-window buf)
     (when (eq context 'exit) (delete-other-windows)))
    (`switch-invisibly (set-buffer buf))
    (_
     (message "Invalid value %s for `edit-comments-window-setup'"
              edit-comments-window-setup)
     (pop-to-buffer-same-window buf))))


;;; Miscellaneous helper functions
(defun edit-comments--ensure-ending-newline ()
  "Ensure that the current buffer ends with a newline."
  (save-excursion
    (goto-char (point-max))
    (let ((nl ?\C-j))
      (unless (eql (char-before) nl)
        (insert-char nl)))))

(defun edit-comments--empty-line-p ()
  "Check if the current line is fully empty according to syntax."
  (save-excursion
    (beginning-of-line)
    (while (and (not (eolp)) (eql ?  (char-syntax (char-after))))
      (forward-char))
    (eolp)))

(defun edit-comments--switch-to-buffer-other-window (&rest args)
  "Wrap the `switch-to-buffer-other-window' function.

ARGS are passed as-is to `switch-to-buffer-other-window', which
see.  See also `org-switch-to-buffer-other-window'."
  (let ((pop-up-frames nil)
        (pop-up-windows nil))
    (apply #'switch-to-buffer-other-window args)))


;;; Debug functions
(defun edit-comments--mark-comment-region (&optional point arg)
  "Mark the current comment region around POINT.

The raw prefix argument ARG will be passed to
`edit-comments--comment-begin' and `edit-comments--comment-end'
as-is.  If inside a comment, point will be at the end of comment,
and a mark will be pushed at the beginning of the comment."
  (interactive "i\nP")
  (let* ((point (or point (point)))
         (begin (edit-comments--comment-begin point arg))
         (end (edit-comments--comment-end point arg)))
    (and begin end
         (prog1 (goto-char end)
           (push-mark begin nil 'activate)))))

(defun edit-comments--kill-current-line ()
  "Kill the current line without removing through newline."
  (save-excursion
    (beginning-of-line)
    (insert 0)
    (beginning-of-line)
    (let ((kill-whole-line nil))
      (kill-line))))

(provide 'edit-comments)
;;; edit-comments.el ends here
