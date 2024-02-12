;;; Directory Local Variables
;;; For more information see (info "(emacs) Directory Variables")

((nil . ((magit-large-repo-set-p . t)
         (lsp-julia-default-environment . "PingPong")
         (eval . (progn
                   (setenv "JULIA_DEV" "1")
                   ;; Use these when using a locally compiled image
                   ;; (setenv "JULIA_CPU_TARGET" "native")
                   ;; (setq julia-repl-switches (concat "--sysimage=" (my/concat-path (or (projectile-project-root) (pwd)) "PingPong.so ")))
                   (when (boundp 'envrc-auto-reload-paths)
                     (cl-pushnew (file-name-concat
                                  (locate-dominating-file (pwd) ".dir-locals.el") ".envrc")
                                 envrc-auto-reload-paths :test #'equal))
                   )))))
