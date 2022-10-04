;;; exercism-modern.el --- Modern interface for exercism -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2022 Ellis Kenyő
;;
;; Author: Ellis Kenyő <me@elken.dev>
;; Maintainer: Ellis Kenyő <me@elken.dev>
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Created: September 15, 2022
;; Modified: September 15, 2022
;; Version: 0.0.1
;; Homepage: https://github.com/elken/exercism-modern
;; Package-Requires: ((emacs "27.1") (request "0.2.0") (pfuture "1.10") (tablist "1.0") (svg-lib "0.2.5"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;; Modern interface for exercism
;;
;; Maps out most of the web interface to be usable in Emacs.
;;
;; `exercism-modern-jump' => open a Dired buffer in the exercism workspace
;; `exercism-modern-view-tracks' => open a buffer of all the available tracks, which can be selected with RET
;; `exercism-modern-track-view-exercises' => open a buffer of all available exercises for the last selected track
;; `exercism-modern-submit' => Submit the solution files to exercism. Invoke with universal argument to pick a buffer.
;;
;;; Code:

(require 'xdg)
(require 'pfuture)
(require 'request)
(require 'image)
(require 'svg-lib)
(require 'tablist)

(defgroup exercism-modern nil
  "Settings related to exercism."
  :group 'external
  :link '(url-link :tag "Homepage" "https://github.com/elken/exercism-modern"))

(defgroup exercism-modern-faces nil
  "Faces related to exercism."
  :group 'exercism-modern)

(defcustom exercism-modern-api-url "https://exercism.org/api/v2"
  "Default url to query resources for."
  :group 'exercism-modern
  :type 'string)

(defcustom exercism-modern-config-file (expand-file-name "exercism/user.json" (xdg-config-home))
  "Default path to the exercism config file."
  :group 'exercism-modern
  :type 'string)

(defcustom exercism-modern-command (executable-find "exercism")
  "Exercism command to run.
Defaults to first entry in $PATH, can be overridden if required."
  :group 'exercism-modern
  :type 'string)

(defcustom exercism-modern-cache-dir (expand-file-name "exercism" (xdg-cache-home))
  "Directory to use for caching resources."
  :group 'exercism-modern
  :type 'string)

(defcustom exercism-modern-missing-icon "https://d24y9kuxp2d7l2.cloudfront.net/assets/graphics/missing-exercise-54cf5afe4add37d9cf717793c91b088a7dd242ef.svg"
  "URL to icon to use for missing icons."
  :group 'exercism-modern
  :type 'string)

(defcustom exercism-modern-exercise-hook nil
  "Hook run when exercism-modern opens an exercise.

The hook is passed the track and the name of the exercise."
  :group 'exercism-modern
  :type 'hook)

(defface exercism-modern-easy-button
  '((((class color) (min-colors 88))
     :background "#EFFFF1" :foreground "#5FB268")
    (t :background "lightgreen" :foreground "darkgreen"))
  "Face used for easy difficulty exercises."
  :group 'exercism-modern-faces)

(defface exercism-modern-medium-button
  '((((class color) (min-colors 88))
     :background "#F7F5E0" :foreground "#A5A256")
    (t :background "lightyellow" :foreground "darkyellow"))
  "Face used for easy difficulty exercises."
  :group 'exercism-modern-faces)

(defface exercism-modern-hard-button
  '((((class color) (min-colors 88))
     :background "#F4EBE5" :foreground "#CB8D6A")
    (t :background "lightorange" :foreground "lightorange"))
  "Face used for easy difficulty exercises."
  :group 'exercism-modern-faces)

(defvar exercism-modern--icon-urls nil
  "Alist of (slug . iconUrl).")

(defvar exercism-modern-current-track nil
  "Current track to pull exercises for.")

(defvar exercism-modern-track-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<return>") #'exercism-modern-track-view-exercises)
    map)
  "Keymap for `exercism-modern-track-mode'.")

(defvar exercism-modern-exercise-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<return>") #'exercism-modern-download-exercise)
    (define-key map (kbd "o") #'exercism-modern-open-exercise)
    map)
  "Keymap for `exercism-modern-exercise-mode'.")

;;;###autoload
(defun exercism-modern-get-config (&optional file-path)
  "Return parsed JSON config.
Optionally check FILE-PATH instead."
  (json-read-file (or file-path exercism-modern-config-file)))

(defun exercism-modern--get-icon (slug)
  "Get an icon for SLUG."
  (let ((path (expand-file-name (format "icons/%s.svg" slug) exercism-modern-cache-dir)))
    (unless (file-exists-p path)
      (mkdir (file-name-directory path) t)
      (let ((url (cdr (assoc slug exercism-modern--icon-urls))))
        (request
          url
          :parser #'buffer-string
          :success (cl-function
                    (lambda (&key data &allow-other-keys)
                      (with-temp-buffer
                        (insert data)
                        (write-region (point-min) (point-max) path))))
          :status-code `((403 . (lambda (&rest _)
                                  (unless (file-exists-p (expand-file-name "icons/_missing.svg" exercism-modern-cache-dir))
                                    (url-copy-file exercism-modern-missing-icon (expand-file-name "icons/_missing.svg" exercism-modern-cache-dir)))
                                  (copy-file (expand-file-name "icons/_missing.svg" exercism-modern-cache-dir) ,path)))))))
    path))

(defun exercism-modern--endpoint->url (endpoint)
  "Convert an ENDPOINT to a callable url."
  (url-encode-url (mapconcat 'identity
                             `(,exercism-modern-api-url ,endpoint)
                             "/")))

(defun exercism-modern-request (endpoint &optional method)
  "Send a request to ENDPOINT using METHOD.
METHOD defaults to GET and must be a valid argument to `request'."
  (let (result)
    (request
      (exercism-modern--endpoint->url endpoint)
      :type (or method "GET")
      :parser (lambda ()
                (let ((json-array-type 'list))
                  (json-read)))
      :headers `(("Authorization" . ,(concat "Bearer " (alist-get 'token (exercism-modern-get-config)))))
      :success (cl-function
                (lambda (&key data &allow-other-keys)
                  (setq result data)))
      :sync t)
    result))

(defun exercism-modern-get-tracks ()
  "Get a list of all tracks."
  (let ((tracks (exercism-modern-request "tracks")))
    (thread-first (alist-get 'tracks tracks)
                  (cl-sort (lambda (lhs rhs)
                             (and (string< (alist-get 'slug lhs) (alist-get 'slug rhs))
                                  (and (alist-get 'is_joined lhs) (alist-get 'is_joined rhs))))))))

(defun exercism-modern-get-exercises (language)
  "Get all exercises for a LANGUAGE slug."
  (alist-get 'exercises (exercism-modern-request (format "tracks/%s/exercises" language))))

(defun exercism-modern--download-finished (_process _status _output)
  "Handle potential errors and callbacks after a download has completed."
  (message "Exercise(s) cloned"))

(defun exercism-modern-download-exercise (&optional callback)
  "Download a given exercise.

If CALLBACK is non-nil, then call that function when downloading
is finished, otherwise call the default
`exercism-modern--download-finished'."
  (interactive)
  (let ((cb-fn (if callback
                   callback
                 #'exercism-modern--download-finished))
        (items (mapcar #'car (tablist-get-marked-items))))
    (if (eq 1 (length items))
        (message "Downloading %s/%s..." exercism-modern-current-track (nth 0 items))
      (message "Downloading %d exercises..." (length items)))
    (cl-loop
     for exercise in items
     do (pfuture-callback
            (list exercism-modern-command
                  "download"
                  (format "--exercise=%s" exercise)
                  (format "--track=%s" exercism-modern-current-track))
          :name (format
                 "exercism-download-%s-%s"
                 exercism-modern-current-track
                 exercise)
          :on-success cb-fn
          :on-error #'exercism-modern--error-callback))))

;;;###autoload
(defun exercism-modern-jump ()
  "Open the exercism workspace in Dired."
  (interactive)
  (dired (alist-get 'workspace (exercism-modern-get-config))))

;;;###autoload
(defun exercism-modern-open-exercise ()
  "Invoked from `exercism-modern-track-mode', open the selected exercise."
  (interactive)
  (when (> (length (tablist-get-marked-items)) 1)
    (message "Can only open one execise at a time."))
  (when (and (eq major-mode 'exercism-modern-exercise-mode)
             (eq (length (tablist-get-marked-items)) 1))
    (let* ((current-ex (tabulated-list-get-id))
           (workspace (alist-get 'workspace (exercism-modern-get-config)))
           (bufname (buffer-name))
           (track (when (string-match "*exercism-modern-\\([a-zA-Z0-9]+\\)*" bufname)
                    (match-string 1 bufname)))
           (ex-dir (concat workspace "/" track "/" current-ex))
           (ex-config-file (concat ex-dir "/.exercism/config.json"))
           (action (lambda (&optional _process _status _output)
                     (message "")       ; clear messages about downloading
                     (run-hook-with-args 'exercism-modern-exercise-hook workspace track current-ex)
                     (if (> (count-windows) 1)
                         ;; there's already a different window configuration, so, for
                         ;; simplicity's sake, delete all the current windows
                         (delete-other-windows))
                     ;; only gets the first item in the list; it's unclear as of
                     ;; yet if this list ever has more than one item
                     (let* ((ex-config (json-read-file ex-config-file))
                            (ex-soln-file (elt (alist-get 'solution (alist-get 'files ex-config)) 0))
                            (ex-soln-file (concat ex-dir "/" ex-soln-file)))
                       (find-file (concat ex-dir "/README.md"))
                       (find-file-other-window ex-soln-file)))))
      ;; TODO add readme note about setting user preference of splitting
      ;; vertically by documenting split-{height,width}-threshold
      (if (file-exists-p ex-config-file)
          (funcall action)
        (message "Downloading %s/%s ..." track current-ex)
        (exercism-modern-download-exercise action)))))

(defun exercism-modern--error-callback (_process _status output)
  "Handle errors from asynchronous PROCESS.

STATUS is the pfuture state for the process, such as the exit
code. OUTPUT is the name of the buffer that contains the process'
error output."
  (with-current-buffer output
    (let* ((err (buffer-substring-no-properties (point-min) (point-max)))
           (err (save-match-data        ; remove trailing whitespace
                 (if (string-match "[ \t\n\r]+\\'" err)
                     (replace-match "" t t err)
                   err))))
      (message "%s" err))))

;;;###autoload
(defun exercism-modern-submit (&optional buffer-prefix-arg)
  "Submit the current exercise.
Uses exercism metadata to get the correct file for submission.
Pass prefix BUFFER-PREFIX-ARG to prompt for a buffer instead."
  (interactive (when (and current-prefix-arg)
                 (list (read-buffer "Buffer to submit: "))))
  (let ((solutions (map-nested-elt
                    (exercism-modern-get-config
                     (expand-file-name ".exercism/config.json" (locate-dominating-file "." ".exercism")))
                    '(files solution))))
    (pfuture-callback
        (list exercism-modern-command
              "submit"
              (if buffer-prefix-arg
                  (buffer-file-name buffer-prefix-arg)
                (mapconcat 'identity solutions " ")))
      :name "exercism-modern-submit"
      :directory default-directory
      :on-success (message "Submitted!")
      :on-error #'exercism-modern--error-callback)))

;;;###autoload
(defun exercism-modern-track-view-exercises ()
  "Invoked from `exercism-modern-track-mode', load the exercises for a given track.

Alternatively, can be invoked from a buffer visiting a exercism
file in its workspace. The track is determined by the current
buffer's relative location to the exercism configured workspace,
e.g. a workspace configuation of \"~/foo/exercism\" will
transform a buffer of ~/foo/exercism/python/two-fer/two_fer.py
into \"python\" as its track."
  (interactive)
  (when (eq major-mode 'exercism-modern-track-mode)
    (setq exercism-modern-current-track (tabulated-list-get-id)))
  ;; try to guess track if we get to this point and
  ;; `exercism-modern-current-track' is nil
  (unless exercism-modern-current-track
    (let ((file-name (buffer-file-name))
          (workspace (alist-get 'workspace (exercism-modern-get-config))))
      (when-let ((track (and (string-prefix-p workspace file-name)
                             (when (string-match (concat workspace "/\\([^/]+\\)/.*") file-name)
                               (match-string 1 file-name)))))
        (setq exercism-modern-current-track track))))
  (message "Fetching exercise list for %s track..." exercism-modern-current-track)
  (pop-to-buffer (format "*exercism-modern-%s*" exercism-modern-current-track) nil)
  (exercism-modern-exercise-mode))

;;;###autoload
(defun exercism-modern-view-tracks ()
  "View a listing of all current exercism tracks."
  (interactive)
  (pop-to-buffer "*exercism-modern-tracks*" nil)
  (exercism-modern-track-mode))

(define-derived-mode exercism-modern-exercise-mode tablist-mode "exercism-modern-exercise-mode"
  "Major mode for viewing exercism exercises."
  (let* ((exercises (exercism-modern-get-exercises exercism-modern-current-track))
         (title-width (+ 6 (cl-loop for exercise in exercises maximize (length (alist-get 'title exercise))))))
    (setq tabulated-list-format (vector
                                 (list "Exercise" title-width t)
                                 (list "Difficulty" 12 nil)
                                 (list "Description" 0 nil))
          tabulated-list-entries (cl-loop
                                  for exercise in exercises
                                  collect
                                  (progn
                                    (add-to-list 'exercism-modern--icon-urls (cons (format "%s/%s" exercism-modern-current-track (alist-get 'slug exercise)) (alist-get 'icon_url exercise)))
                                    (let* ((slug (alist-get 'slug exercise))
                                           (icon (exercism-modern--get-icon (format "%s/%s" exercism-modern-current-track (alist-get 'slug exercise))))
                                           (title (alist-get 'title exercise))
                                           (blurb (alist-get 'blurb exercise))
                                           (difficulty (alist-get 'difficulty exercise))
                                           (is-unlocked (not (eq :json-false (alist-get 'is_unlocked exercise))))
                                           (text-face (if is-unlocked 'default 'shadow))
                                           (foreground (face-attribute (intern (format "exercism-modern-%s-button" difficulty)) :foreground))
                                           (background (face-attribute (intern (format "exercism-modern-%s-button" difficulty)) :background)))
                                      (list slug
                                            (vector (concat
                                                     (propertize "★  " 'face 'warning)
                                                     (propertize
                                                      " "
                                                      'display
                                                      `(image
                                                        :margin (2 . 2)
                                                        :ascent center
                                                        :width 15
                                                        :type ,(image-type (alist-get 'icon_url exercise))
                                                        :file ,icon))
                                                     (propertize title 'face text-face))
                                                    (propertize
                                                     " "
                                                     'display
                                                     (svg-lib-button "square" (capitalize difficulty) nil
                                                                     :font-weight 900
                                                                     :scale 0.6
                                                                     :radius 6
                                                                     :background background
                                                                     :foreground foreground))
                                                    (propertize blurb 'face text-face))))))
          tabulated-list-padding 4)
    (message "") ;; clear any previous messages
    (tabulated-list-init-header)
    (use-local-map exercism-modern-exercise-mode-map)
    (tabulated-list-print t)
    (tablist-minor-mode)))

(define-derived-mode exercism-modern-track-mode tabulated-list-mode "exercism-modern-track-mode"
  "Major mode for viewing exercism tracks."
  (let* ((tracks (exercism-modern-get-tracks)))
    (setq tabulated-list-format (vector (list "Title" (+ 6 (cl-loop for track in tracks maximize (length (alist-get 'title track)))) t)
                                        (list "Joined" 8 t)
                                        (list "Concepts" 8 nil)
                                        (list "Exercises" 10 nil)
                                        (list "Solutions" 8 nil))
          tabulated-list-entries (cl-loop
                                  for track in tracks
                                  collect
                                  (progn
                                    (add-to-list 'exercism-modern--icon-urls (cons (alist-get 'slug track) (alist-get 'icon_url track)))
                                    (let* ((slug (alist-get 'slug track))
                                           (icon (exercism-modern--get-icon slug))
                                           (title (alist-get 'title track))
                                           (num-concepts (alist-get 'num_concepts track))
                                           (num-exercises (alist-get 'num_exercises track))
                                           (is-joined (alist-get 'is_joined track))
                                           (num-learnt-concepts (alist-get 'num_learnt_concepts track))
                                           (num-completed-exercises (alist-get 'num_completed_exercises track))
                                           (num-solutions (alist-get 'num_solutions track)))
                                      (list slug
                                            (vector (concat
                                                     (propertize
                                                      " "
                                                      'display
                                                      `(image
                                                        :margin (2 . 2)
                                                        :ascent center
                                                        :width 15
                                                        :type ,(image-type (alist-get 'icon_url track))
                                                        :file ,icon))
                                                     title)
                                                    (if is-joined (propertize "✓" 'face 'success) (propertize "⊘" 'face 'error))
                                                    (concat
                                                     (number-to-string (if (numberp num-learnt-concepts) num-learnt-concepts 0))
                                                     "/"
                                                     (number-to-string (if (numberp num-concepts) num-concepts 0)))
                                                    (concat
                                                     (number-to-string (if (numberp num-completed-exercises) num-completed-exercises 0))
                                                     "/"
                                                     (number-to-string (if (numberp num-exercises) num-exercises 0)))
                                                    (number-to-string (if (numberp num-learnt-concepts)  num-learnt-concepts 0))
                                                    (number-to-string (if (numberp num-solutions)  num-solutions 0)))))))
          tabulated-list-padding 4)
    (tabulated-list-init-header)
    (use-local-map exercism-modern-track-mode-map)
    (tabulated-list-print t)))

(provide 'exercism-modern)

;;; exercism-modern.el ends here
