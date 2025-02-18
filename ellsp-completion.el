;;; ellsp-completion.el --- Completion Handler  -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Shen, Jen-Chieh

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Completion Handler.
;;

;;; Code:

(require 'company)
(require 'company-capf)
(require 'lsp-completion)

(cl-defun ellsp--list-completion-items (list &key transform kind)
  ""
  (setq transform (or transform #'identity))
  (apply #'vector
         (mapcar
          (lambda (item)
            (let ((completion (funcall transform item)))
              (lsp-make-completion-item
               :label (if (listp completion)
                          (plist-get completion :label)
                        completion)
               :kind (if (listp completion)
                         (plist-get completion :kind)
                       (or kind lsp/completion-item-kind-text)))))
          list)))

(defun ellsp--completions-bounds ()
  ""
  (with-syntax-table emacs-lisp-mode-syntax-table
    (message "completion bounds point %s" (point))
    (let* ((pos (point))
           (beg (condition-case nil
                    (save-excursion
                      (backward-sexp 1)
                      (skip-chars-forward "`',‘#")
                      (point))
                  (scan-error pos)))
           (end
            (unless (or (eq beg (point-max))
                        (member (char-syntax (char-after beg))
                                '(?\" ?\()))
              (condition-case nil
                  (save-excursion
                    (goto-char beg)
                    (forward-sexp 1)
                    (skip-chars-backward "'’")
                    (when (>= (point) pos)
                      (point)))
                (scan-error pos)))))
      (list beg end))))

(defun ellsp--function-completions ()
  ;; only used to extract start and end... we can reimplement it later
  (-when-let ((beg end) (ellsp--completions-bounds))
    (message "bounds %s %s" beg end)
    (let* ((candidates)
           (funpos (eq (char-before beg) ?\())
           (prefix (buffer-substring-no-properties beg end)))
      (message "prefix %s" prefix)
      candidates)))

(defun ellsp--convert-kind (kind)
  "Convert company's KIND to lsp-mode's kind."
  (setq kind (ellsp-2str kind))
  (cl-position (capitalize kind) lsp-completion--item-kind :test #'equal))

(defun ellsp--capf-completions ()
  "Fallback completions engine is the `elisp-completion-at-point'."
  (let* ((prefix (company-capf 'prefix))
         (candidates (company-capf 'candidates prefix)))
    (mapcar (lambda (candidate)
              (lsp-make-completion-item
               :label candidate
               :documentation? (company-capf 'annotation candidate)
               :deprecated? (if (null (company-capf 'deprecated candidate))
                                json-false
                              t)
               :kind? (ellsp--convert-kind (company-capf 'kind candidate))))
            candidates)))

(defun ellsp--handle-textDocument/completion (id method params)
  "Handle method `textDocument/completion'."
  (-let* (((&CompletionParams :text-document (&TextDocumentIdentifier :uri)
                              :position (&Position :line :character))
           params)
          (file (lsp--uri-to-path uri))
          (buffer (ellsp-get-buffer ellsp-workspace file)))
    (when buffer
      (with-current-buffer buffer
        (goto-char (point-min))
        (forward-line line)
        (forward-char character)
        (lsp--make-response
         id
         (lsp-make-completion-list
          :is-incomplete json-false
          :items (apply #'vector (ellsp--capf-completions))))))))

(provide 'ellsp-completion)
;;; ellsp-completion.el ends here
