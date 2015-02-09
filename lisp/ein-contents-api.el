;;; ein-contents-api.el --- Interface to Jupyter's Contents API

;; Copyright (C) 2015 - John Miller

;; Authors: Takafumi Arakaki <aka.tkf at gmail.com>
;;          John M. Miller <millejoh at mac.com>

;; This file is NOT part of GNU Emacs.

;; ein-contents-api.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-contents-api.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-notebooklist.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;;
;;; An interface to the Jupyter Contents API as described in
;;; https://github.com/ipython/ipython/wiki/IPEP-27%3A-Contents-Service.
;;;

;;

;;; Code:

(require 'ein-core)
(require 'ein-utils)

(defstruct ein:$content
  "Content returned from the Jupyter notebook server:
`ein:$content-url-or-port'
  URL or port of Jupyter server.

`ein:$content-name 
  The name/filename of the content. Always equivalent to the last 
  part of the path field

`ein:$content-path
 The full file path. It will not start with /, and it will be /-delimited.

`ein:$content-type
 One of three values: :directory, :file, :notebook.

`ein:$content-writable
  Indicates if requester has permission to modified the requested content.

`ein:$content-created

`ein:$content-last-modified

`ein:$content-mimetype
  Specify the mime-type of :file content, null otherwise.

`ein:$content-raw-content
  Contents of resource as returned by Jupyter.  Depending on content-type will hold:
    :directory : JSON list of models for each item in the directory.
    :file      : Text of file as a string or base64 encoded string if mimetype
                 is other than 'text/plain'.
    :notebook  : JSON structure of the file.

`ein:$content-format
  Value will depend on content-type:
    :directory : :json.
    :file      : Either :text or :base64
    :notebook  : :json.
"
  url-or-port
  name
  path
  type
  writable
  created
  last-modified
  mimetype
  raw-content
  format)

(defun ein:content-url (url-or-port path &optional name)
  (if name
      (ein:url url-or-port "api/contents" path name)
    (ein:url url-or-port "api/contents" path)))

(defun ein:content-url-legacy (url-or-port path &optional name)
  "Generate content url's for IPython Notebook version 2.x"
  (if name
      (ein:url url-or-port "api/notebooks" path name)
    (ein:url url-or-port "api/notebooks" path)))

(defun ein:content-query-contents (path &optional url-or-port force-sync)
  "Return the contents of the object at the specified path from the Jupyter server."
  (let* ((url-or-port (or url-or-port (ein:default-url-or-port)))
         (url (ein:content-url url-or-port path))
         (new-content (make-ein:$content :url-or-port url-or-port)))
    (if (= 2 (ein:query-ipython-version url-or-port))
        (setq new-content (ein:content-query-contents-legacy path url-or-port force-sync))
      (ein:query-singleton-ajax
       (list 'content-query-contents url-or-port path)
       url
       :type "GET"
       :parser #'ein:json-read
       :sync force-sync
       :success (apply-partially #'ein:new-content new-content)
       :error (apply-partially #'ein-content-list-contents-error url)))
    new-content))

(defun ein:content-query-contents-legacy (path &optional url-or-port force-sync)
  "Return contents of boject at specified path for IPython Notebook versions 2.x"
  (let* ((url-or-port (or url-or-port (ein:default-url-or-port)))
         (url (ein:content-url-legacy url-or-port path))
         (new-content (make-ein:$content :url-or-port url-or-port)))
    (ein:query-singleton-ajax
     (list 'content-query-contents-legacy url-or-port path)
     url
     :type "GET"
     :parser #'ein:json-read
     :sync force-sync
     :success (apply-partially #'ein:list-contents-legacy-success path new-content)
     :error (apply-partially #'ein-content-query-contents-error url))
    new-content))

(defun ein:fix-legacy-content-data (data)
  (if (listp (car data))
      (loop for item in data
            collecting
            (ein:fix-legacy-content-data item))
    (if (string= (plist-get data :path) "")
            (plist-put data :path (plist-get data :name))
      (plist-put data :path (format "%s/%s" (plist-get data :path) (plist-get data :name))))))

(defun* ein:list-contents-legacy-success (path content &key data &allow-other-keys)
  (let* ((url-or-port (ein:$content-url-or-port content)))
    (setf (ein:$content-name content) (substring path (or (cl-position ?/ path) 0))
          (ein:$content-path content) path 
          (ein:$content-type content) "directory"
                                        ;(ein:$content-created content) (plist-get data :created)
                                        ;(ein:$content-last-modified content) (plist-get data :last_modified)
          (ein:$content-format content) nil
          (ein:$content-writable content) nil
          (ein:$content-mimetype content) nil
          (ein:$content-raw-content content) (ein:fix-legacy-content-data data))))

(defun* ein:new-content (content &key data &allow-other-keys)
  (setf (ein:$content-name content) (plist-get data :name)
        (ein:$content-path content) (plist-get data :path)
        (ein:$content-type content) (plist-get data :type)
        (ein:$content-created content) (plist-get data :created)
        (ein:$content-last-modified content) (plist-get data :last_modified)
        (ein:$content-format content) (plist-get data :format)
        (ein:$content-writable content) (plist-get data :writable)
        (ein:$content-mimetype content) (plist-get data :mimetype)
        (ein:$content-raw-content content) (plist-get data :content)))

(defun* ein:content-query-contents-error (url &key symbol-status response &allow-other-keys)
  (ein:log 'verbose
    "Error thrown: %S" (request-response-error-thrown response))
  (ein:log 'error
    "Content list call %s failed with status %s." url symbol-status))

;; ***

(defvar *ein:content-hierarchy* (make-hash-table))

(defun ein:make-content-hierarchy (path url-or-port)
  (let* ((node (ein:content-query-contents path url-or-port t))
         (items (ein:$content-raw-content node)))
    (ein:flatten (loop for item in items
                   for c = (make-ein:$content :url-or-port url-or-port)
                   do (ein:new-content c :data item)
                   collect
                   (cond ((string= (ein:$content-type c) "directory")
                          (cons c
                                (ein:make-content-hierarchy (ein:$content-path c) url-or-port)))
                         (t c))))))

(defun ein:refresh-content-hierarchy (&optional url-or-port)
  (let ((url-or-port (or url-or-port (ein:default-url-or-port))))
    (setf (gethash url-or-port *ein:content-hierarchy*)
          (ein:make-content-hierarchy ""  url-or-port))))

;;; Get file contents

(defun ein:content-rename (content new-path)
  (let ((url-or-port (ein:$content-url-or-port content))
        (path (ein:$content-path content)))
    (ein:query-singleton-ajax
     (list 'get-file url-or-port path)
     (ein:content-url url-or-port path)
     :type "PATCH"
     :data (json-encode `(:path ,new-path))
     :parser #'ein:json-read
     :success (apply-partially #'update-content-path content)
     :error (apply-partially #'ein-content-rename-error path))))

(defun* update-content-path (content &key data &allow-other-keys)
  (setf (ein:$content-path content) (plist-get data :path)
        (ein:$content-name content) (plist-get data :name)
        (ein:$content-last-modified content) (plist-get data :last_modified)))

(defun* ein:content-rename-error (path &key symbol-status response &allow-other-keys)
  (ein:log 'verbose
    "Error thrown: %S" (request-response-error-thrown response))
  (ein:log 'error
    "Renaming content %s failed with status %s." path symbol-status))




(provide 'ein-contents-api)
