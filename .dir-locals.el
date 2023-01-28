;;; Directory Local Variables
;;; For more information see (info "(emacs) Directory Variables")

((nil . ((magit-large-repo-set-p . t)
         (eval . (progn
                   (setenv "JULIA_DEV" "1")
                   (setenv "JULIA_NO_TMP" "1")
                   (setenv "CONDA_PKG_ENV" (concat (getenv "PROJECT_DIR") ".CondaPkg"))
                   )))))
