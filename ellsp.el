;;; ellsp.el --- Elisp Language Server  -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Shen, Jen-Chieh

;; Author: Shen, Jen-Chieh <jcs090218@gmail.com>
;; Maintainer: Shen, Jen-Chieh <jcs090218@gmail.com>
;; URL: https://github.com/jcs-elpa/ellsp
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (lsp-mode "6.0.1") (log4e "0.1.0") (dash "2.14.1") (s "1.12.0") (company "0.8.12"))
;; Keywords: convenience lsp

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
;; Elisp Language Server
;;

;;; Code:

(require 'pcase)
(require 'lsp-mode)
(require 'dash)
(require 's)

(require 'ellsp-log)
(require 'ellsp-tdsync)
(require 'ellsp-completion)
(require 'ellsp-hover)
(require 'ellsp-signature)

(defgroup ellsp nil
  "Elisp Language Server."
  :prefix "ellsp-"
  :group 'tool
  :link '(url-link :tag "Repository" "https://github.com/jcs-elpa/ellsp"))

;; XXX: Don't know why \r\n won't work with VSCode; and don't
;; know why \n will work. :/
;;
;; This is currently a mystry to me!
(defcustom ellsp-eol "\n"
  "EOL for send messages."
  :type 'string
  :group 'ellsp)

(defvar ellsp--running-p t
  "Non-nil when the server is still running.")

(defvar ellsp--initialized-p nil
  "Non-nil when it initialize successfully.")

(defun ellsp-2str (obj)
  "Convert OBJ to string."
  (format "%s" obj))

(defun ellsp-send-response (msg)
  "Send response MSG."
  (when (or (hash-table-p msg)
            (and (listp msg) (plist-get msg :jsonrpc)))
    (setq msg (lsp--json-serialize msg)))
  (setq msg (format "Content-Length: %d%s%s%s" (string-bytes msg)
                    ellsp-eol ellsp-eol
                    msg))
  (princ msg)
  (terpri)
  msg)

(defun ellsp-form-to-lsp-range (form)
  "Convert FORM to LSP range."
  (lsp-make-range
   :start (lsp-make-position
           :line (1- (oref form line))
           :character (oref form column))
   :end (lsp-make-position
         :line (1- (oref form end-line))
         :character  (oref form end-column))))

(defun ellsp--initialize (id params)
  "Initialize the language server."
  (lsp--make-response
   id
   (lsp-make-initialize-result
    :server-info (lsp-make-server-info
                  :name "ellsp"
                  :version? "0.1.0")
    :capabilities (lsp-make-server-capabilities
                   :hover-provider? t
                   :text-document-sync? (lsp-make-text-document-sync-options
                                         :open-close? t
                                         :save? t
                                         :change? 1)
                   :completion-provider? (lsp-make-completion-options
                                          :resolve-provider? json-false)
                   :signature-help-provider? (lsp-make-signature-help-options
                                              :trigger-characters? [" "])))))

(defun ellsp--initialized ()
  "After server initialization."
  (setq ellsp--initialized-p t)
  nil)

(defun ellsp--shutdown ()
  "Shutdown language server."
  (setq ellsp--running-p nil))

(defun ellsp--on-request (id method params)
  "On request callback."
  (message "method: %s" method)
  (let ((res
         (pcase method
           ("initialize"                 (ellsp--initialize id params))
           ("initialized"                (ellsp--initialized))
           ("shutdown"                   (ellsp--shutdown))
           ("textDocument/didOpen"       (ellsp--handle-textDocument/didOpen params))
           ("textDocument/didSave"       (ellsp--handle-textDocument/didSave))
           ("textDocument/didChange"     (ellsp--handle-textDocument/didChange id method params))
           ("textDocument/completion"    (ellsp--handle-textDocument/completion id method params))
           ("textDocument/hover"         (ellsp--handle-textDocument/hover id method params))
           ("textDocument/signatureHelp" (ellsp--handle-textDocument/signatureHelp id)))))
    (if (not res)
        (message "<< %s" "no response")
      (message "<< %s" (lsp--json-serialize res))
      (ellsp-send-response (lsp--json-serialize res)))))

(defun ellsp--get-content-length (input)
  "Return the content length from INPUT."
  (string-to-number (nth 1 (split-string input ": "))))

(defun ellsp--check-content-type (input length)
  "Return non-nil when INPUT match content's LENGTH."
  (and length
       (= (length input) length)))

(defvar ellsp-next-input nil)

(defun ellsp-stdin-loop ()
  "Reads from standard input in a loop and process incoming requests."
  (ellsp--info "Starting the language server...")
  (let ((input)
        (has-header)
        (content-length))
    (while (and ellsp--running-p
                (progn
                  (setq input (or ellsp-next-input
                                  (read-from-minibuffer "")))
                  input))
      (unless (string-empty-p input)
        ;; XXX: Function `s-replace' is used to avoid the following error:
        ;;
        ;; Invalid use of `\' in replacement text ...
        (ellsp--info (s-replace "\\" "\\\\" input)))
      (setq ellsp-next-input nil)  ; Reset
      (cond
       ((string-empty-p input) )
       ((and (null content-length)
             (string-prefix-p "content-length: " input t))
        (setq content-length (ellsp--get-content-length input)))
       (content-length
        (when (string-match-p "content-length: [0-9\r\n]+$" input)
          (with-temp-buffer
            (insert input)
            (when (search-backward "content-length: " nil t)
              (setq input (buffer-substring-no-properties (point-min) (point))
                    ellsp-next-input (buffer-substring-no-properties (point) (point-max))))))
        (-let* (((&JSONResponse :params :method :id) (lsp--read-json input)))
          (condition-case err
              (ellsp--on-request id method params)
            (error (ellsp--error "Ellsp error: %s"
                                 (error-message-string err)))))
        (setq content-length nil))))))

;;;###autoload
(defun ellsp-register ()
  (interactive)
  (add-to-list 'lsp-language-id-configuration '(emacs-lisp-mode . "emacs-lisp"))
  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection
                     (lambda ()
                       (cond
                        ((locate-dominating-file (buffer-file-name) "Eask")
                         (list "eask" "exec"
                               (pcase system-type
                                 ('windows-nt
                                  "ellsp-win.exe")
                                 ('darwin
                                  "ellsp-macos")
                                 ((or 'gnu 'gnu/linux 'gnu/kfreebsd)
                                  "ellsp-linux"))))
                        (t (error "Ellsp Language Server can only run with Eask")))))
    :major-modes '(emacs-lisp-mode)
    :priority 1
    :server-id 'ellsp)))

(provide 'ellsp)
;;; ellsp.el ends here
