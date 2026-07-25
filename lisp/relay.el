;;; relay.el --- Async remote file layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kevin Shih

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Public entry point for relay.  The implementation is split by subsystem
;; so transport, prefetch, completion, and file-save work can evolve without
;; forcing every contributor to parse or edit one monolithic file.

;;; Code:

(require 'relay-core)
(require 'relay-prefetch)
(require 'relay-content-prefetch)
(require 'relay-prefetch-ui)
(require 'relay-completion)
(require 'relay-conflict)
(require 'relay-file-handler)

(provide 'relay)
;;; relay.el ends here
