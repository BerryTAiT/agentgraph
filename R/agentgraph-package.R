#' @keywords internal
"_PACKAGE"

#' @useDynLib agentgraph, .registration = TRUE
#' @importFrom Rcpp sourceCpp
#' @importFrom utils modifyList
#' @importFrom utils tail
#' @importFrom stats setNames
NULL

# `.fn` is a mirai launcher name that is injected at run time through the
# `.args` argument (see run_async()/batch_submit()); declare it so static
# code checks do not report a false positive. `skip` is the testthat skip
# helper used inside a test file.
utils::globalVariables(c(".fn", "skip"))
