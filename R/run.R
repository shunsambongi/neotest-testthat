parse_args <- function() {
  raw <- commandArgs(trailingOnly = TRUE)

  pointer <- 1L
  args <- list()
  while (pointer <= length(raw)) {
    curr <- raw[pointer]
    if (grepl("^--", curr)) {
      pointer <- pointer + 1
      name <- sub("^--", "", curr)
      args[[name]] <- raw[pointer]
    } else {
      stop("Failed to parse commandline argument: ", curr)
    }
    pointer <- pointer + 1
  }

  args
}

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

NeotestReporter <- R6::R6Class("NeotestReporter",
  inherit = testthat::Reporter,
  public = list(
    filename = NULL,
    results = NULL,
    lookup = NULL,
    initialize = function(lookup, ...) {
      super$initialize(...)

      self$lookup <- lapply(jsonlite::fromJSON(lookup), function(id_lines) {
        sort(unlist(id_lines, use.names = TRUE), decreasing = TRUE)
      })

      names(self$lookup) <- vapply(
        names(self$lookup), normalizePath, character(1L),
        mustWork = TRUE, USE.NAMES = FALSE
      )
    },
    start_reporter = function() {
      self$results <- list()
    },

    # file
    start_file = function(filename) {
      self$filename <- filename
    },

    # test
    start_test = function(context, test) {
      if (is.null(context)) {
        testthat::context_start_file(self$filename)
      }
    },
    add_result = function(context, test, result) {
      srcfile <- attr(result$srcref, "srcfile")
      filename <- normalizePath(
        paste0(srcfile$wd, "/", srcfile$filename),
        mustWork = TRUE
      )
      expectation_line <- result$srcref[1]
      id_lines <- self$lookup[[filename]]
      id <- names(self$lookup[[filename]][id_lines <= expectation_line][1])

      self$set_current_test(id)

      neotest_result <- self$get_current_test_result()

      if (testthat:::expectation_success(result) && is.null(neotest_result$status)) {
        neotest_result$status <- "passed"
      } else if (testthat:::expectation_skip(result)) {
        neotest_result$status <- "skipped"
      } else if (testthat:::expectation_broken(result)) {
        first_line <- strsplit(
          result$message,
          split = "\n"
        )[[1]][1]

        neotest_result <- self$add_error(
          neotest_result,
          message = first_line, line = expectation_line
        )
      }
      self$set_current_test_result(neotest_result)
    },
    end_test = function(context, test) {
      result <- self$get_current_test_result()

      if (length(result$error)) {
        result$status <- "failed"
      }

      self$set_current_test_result(result)
      self$reset_current_test()
    },
    end_reporter = function() {
      jsonlite::write_json(self$results, self$out, auto_unbox = TRUE)
    },

    # helpers
    current_test_id = NULL,
    add_error = function(result, message, line) {
      line <- line - 1L # make it 0-indexed
      error <- list(message = message, line = line)
      errors <- result$errors %||% list()
      result$errors <- c(errors, list(error))
      invisible(result)
    },
    set_current_test = function(id) {
      self$current_test_id <- id
    },
    reset_current_test = function() {
      self$current_test_id <- list(NULL)
    },
    get_current_test_result = function() {
      self$results[[self$current_test_id]]
    },
    set_current_test_result = function(result) {
      self$results[[self$current_test_id]] <- result
      invisible(result)
    }
  ), # public
)


args <- parse_args()

reporter <- testthat::MultiReporter$new(
  reporters = list(
    NeotestReporter$new(file = args$out, lookup = args$lookup),
    testthat::ProgressReporter$new()
  )
)

if (identical(args$type, "dir")) {
  testthat::test_dir(
    args$path,
    reporter = reporter,
    load_package = "source"
  )
} else if (identical(args$type, "file")) {
  testthat::test_file(
    args$path,
    reporter = reporter,
    load_package = "source"
  )
} else {
  stop("Unsupported type: ", args$type)
}
