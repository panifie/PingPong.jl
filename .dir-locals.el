;;; Directory Local Variables
;;; For more information see (info "(emacs) Directory Variables")

((nil . ((magit-large-repo-set-p . t)
         (lsp-julia-default-environment . "PingPong")
         (eval . (progn
                   (setenv "JULIA_DEV" "1")
                   (setenv "JULIA_NO_TMP" "1")
                   (when (boundp 'envrc-auto-reload-paths)
                     (cl-pushnew (file-name-concat
                                  (locate-dominating-file (pwd) ".dir-locals.el") ".envrc")
                                 envrc-auto-reload-paths :test #'equal))
                   )))))
