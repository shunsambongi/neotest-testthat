library(testthat)

main <- function() {
  args <- parse_args()

  neotest_reporter <- NeotestReporter$new(
    file = args$out, lookup = args$lookup
  )

  if (identical(args$type, "test") || identical(args$type, "namespace")) {
    neotest_reporter$real_filename <- normalizePath(
      args$realpath,
      mustWork = TRUE
    )
  }

  test_args <- list(
    args$path,
    reporter = MultiReporter$new(
      reporters = list(neotest_reporter, ProgressReporter$new())
    ),
    load_package = "source"
  )

  run_test <- switch(args$type,
    dir = {
      test_args$load_package <- NULL
      test_local
    },
    file = test_file,
    test = test_pruned(args$root),
    namespace = test_pruned(args$root),
    stop("Unsupported test node type: ", args$type)
  )

  do.call(run_test, test_args)
}

NeotestReporter <- R6::R6Class("NeotestReporter", # nolint: object_name
  inherit = testthat::Reporter,
  public = list(
    filename = NULL,
    real_filename = NULL,
    lookup = NULL,
    results = NULL,
    initialize = function(lookup, ..., real_filename = NULL) {
      super$initialize(...)

      self$real_filename <- real_filename

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
    start_file = function(filename) {
      self$filename <- filename
    },
    start_test = function(context, test) {
      if (
        !is.null(self$real_filename) &&
          grepl("neotest-[a-zA-Z0-9]+", context)
      ) {
        context_start_file(basename(self$real_filename))
      } else if (is.null(context)) {
        context_start_file(self$filename)
      }
    },
    add_result = function(context, test, result) {
      filename <- if (is.null(self$real_filename)) {
        srcfile <- attr(result$srcref, "srcfile")
        normalizePath(
          paste0(srcfile$wd, "/", srcfile$filename),
          mustWork = TRUE
        )
      } else {
        self$real_filename
      }

      expectation_line <- result$srcref[1]
      id_lines <- self$lookup[[filename]]
      id <- names(self$lookup[[filename]][id_lines <= expectation_line][1])

      self$set_current_test(id)

      neotest_result <- self$get_current_test_result()

      if (
        testthat:::expectation_success(result) && is.null(neotest_result$status)
      ) {
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

# helper functions
`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

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

test_pruned <- function(root) {
  function(path, ...) {
    rand_chars <- c(letters, LETTERS, as.character(0:9))
    suffix <- paste(sample(rand_chars, 10, replace = TRUE), collapse = "")
    temp <- file.path(
      root, "tests", "testthat", paste0("test-neotest-", suffix, ".R")
    )
    on.exit(file.remove(temp))
    file.copy(from = path, to = temp)
    test_file(temp, ...)
  }
}

# run tests
main()
