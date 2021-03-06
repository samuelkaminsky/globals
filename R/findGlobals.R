## This function is equivalent to:
##    fun <- as_function(expr, envir = envir, ...)
##    codetools::findGlobals(fun, merge = TRUE)
## but we expand it here to make it more explicit
## what is going on.
#' @importFrom codetools makeUsageCollector findLocalsList walkCode
find_globals_conservative <- function(expr, envir, ..., trace = FALSE) {
  objs <- character()

  enter <- function(type, v, e, w) {
    objs <<- c(objs, v)
  }

  if (is.function(expr)) {
    if (typeof(expr) != "closure") return(character(0L)) # e.g. `<-`
    fun <- expr
    w <- makeUsageCollector(fun, name = "<anonymous>", enterGlobal = enter)
    if (trace) w <- inject_tracer_to_walker(w)
    collect_usage_function(fun, name = "<anonymous>", w)
  } else {
    ## From codetools::findGlobals():
    fun <- as_function(expr, envir = envir, ...)
    # codetools::collectUsage(fun, enterGlobal = enter)

    ## The latter becomes equivalent to (after cleanup):
    w <- makeUsageCollector(fun, name = "<anonymous>", enterGlobal = enter)
    w$env <- new.env(hash = TRUE, parent = w$env)
    if (trace) w <- inject_tracer_to_walker(w)
    
    locals <- findLocalsList(list(expr))
    for (name in locals) assign(name, value = TRUE, envir = w$env)
    walkCode(expr, w)
  }

  unique(objs)
}


#' @importFrom codetools makeUsageCollector walkCode
find_globals_liberal <- function(expr, envir, ..., trace = FALSE) {
  objs <- character()

  enter <- function(type, v, e, w) {
    objs <<- c(objs, v)
  }

  if (is.function(expr)) {
    if (typeof(expr) != "closure") return(character(0L)) ## e.g. `<-`
    fun <- expr
    w <- makeUsageCollector(fun, name = "<anonymous>", enterGlobal = enter)
    if (trace) w <- inject_tracer_to_walker(w)
    collect_usage_function(fun, name = "<anonymous>", w)
  } else {
    fun <- as_function(expr, envir = envir, ...)
    w <- makeUsageCollector(fun, name = "<anonymous>", enterGlobal = enter)
    if (trace) w <- inject_tracer_to_walker(w)
    walkCode(expr, w)
  }

  unique(objs)
}


#' @importFrom codetools makeUsageCollector walkCode
find_globals_ordered <- function(expr, envir, ..., trace = FALSE) {
  selfassign <- getOption("globals.selfassign", TRUE)
  
  class <- name <- character()
  
  enter_local <- function(type, v, e, w) {
    ## LH <- RH: Handle cases where a global variable exists in RH and LH
    ##           assigns a local variable with the same name, e.g. x <- x + 1.
    ##           In such case we want to detect 'x' as a global variable.
    if (selfassign && (type == "<-" || type == "=")) {
      rhs <- e[[3]]
      globals <- all.names(rhs)
      if (length(rhs) == 3 && globals[1] %in% c("::", ":::")) {
        ## Case: a <- pkg::a
      } else if (v %in% globals) {
        class <<- c(class, "global")
        name <<- c(name, v)
      }
    }

    class <<- c(class, "local")
    name <<- c(name, v)
  }

  enter_global <- function(type, v, e, w) {
    class <<- c(class, "global")
    name <<- c(name, v)
    
    ## Also walk formulas to identify globals
    if (type == "function") {
      if (v == "~") {
        stop_if_not(identical(e[[1]], as.symbol("~")))
        expr <- e[-1]
        for (kk in seq_along(expr)) {
          globals <- find_globals_ordered(expr = expr[[kk]], envir = w$env)
          if (length(globals) > 0) {
            class <<- c(class, rep("global", times = length(globals)))
            name <<- c(name, globals)
          }
        }
      } else if (selfassign && (v == "<-" || v == "=")) {
        ## LH <- RH: Handle cases where a global variable exists in LH in the
        ##           form of x[1] <- 0, which will cause 'x' to be called a
        ##           local variable later unless called global here.
        lhs <- e[[2]]
        if (length(lhs) >= 2) {
          ## Cases: a[1] <- 0, names(a) <- "x", names(a)[1] <- "x"
          ## Skip first symbol, because it'll be handled up later as
          ## an assignment function, e.g. `[<-` and `names<-`
          globals <- find_globals_ordered(expr = lhs, envir = w$env)
          if (length(globals) > 0) {
            class <<- c(class, rep("global", times = length(globals)))
            name <<- c(name, globals)
          }
        }
      }
    }
  }

  ## A function or an expression?
  if (is.function(expr)) {
    if (typeof(expr) != "closure") return(character(0L)) ## e.g. `<-`
    fun <- expr

    w <- makeUsageCollector(fun, name = "<anonymous>",
                            enterLocal = enter_local,
                            enterGlobal = enter_global)
    if (trace) w <- inject_tracer_to_walker(w)
    collect_usage_function(fun, name = "<anonymous>", w)
  } else {
    fun <- as_function(expr, envir = envir, ...)
    w <- makeUsageCollector(fun, name = "<anonymous>",
                            enterLocal = enter_local,
                            enterGlobal = enter_global)
    if (trace) w <- inject_tracer_to_walker(w)
    walkCode(expr, w)
  }

  ## Drop duplicated names
  dups <- duplicated(name)
  class <- class[!dups]
  name <- name[!dups]

  unique(name[class == "global"])
}


#' @param dotdotdot TBD.
#'
#' @param trace TBD.
#'
#' @return \code{findGlobals()} returns a character vector.
#'
#' @rdname globalsOf
#' @export
findGlobals <- function(expr, envir = parent.frame(), ..., tweak = NULL,
                        dotdotdot = c("warning", "error", "return", "ignore"),
                        method = c("ordered", "conservative", "liberal"),
                        substitute = FALSE, unlist = TRUE, trace = FALSE) {
  method <- match.arg(method, choices = c("ordered", "conservative", "liberal"))
  dotdotdot <- match.arg(dotdotdot, choices = c("warning", "error", "return", "ignore"))

  if (substitute) expr <- substitute(expr)

  debug <- mdebug("findGlobals(..., dotdotdot = '%s', method = '%s', unlist = %s) ...", dotdotdot, method, unlist)

  if (is.list(expr)) {
    debug && mdebug(" - expr: <a list of length %d>", .length(expr))

    ## NOTE: Do *not* look for types that we are interested in, but instead
    ## look for types that we are *not* interested.  The reason for this that
    ## in future versions of R there might be new types added that may contain
    ## globals and with this approach those types will also be scanned.
    basicTypes <- c("logical", "integer", "double", "complex", "character",
                    "raw", "NULL")

    ## Skip elements in 'expr' of basic types that cannot contain globals
    types <- unlist(list_apply(expr, FUN = typeof), use.names = FALSE)
    keep <- !(types %in% basicTypes)

    ## Don't use expr[keep] here, because that may use S3 dispatching
    ## depending on class(expr)
    expr <- .subset(expr, keep)

    ## Early stopping?
    if (.length(expr) == 0) {
      debug && mdebug(" - globals found: [0] <none>")
      debug && mdebug("findGlobals(..., dotdotdot = '%s', method = '%s', unlist = %s) ... DONE", dotdotdot, method, unlist) #nolint
      return(character(0L))
    }
    
    globals <- list_apply(expr, FUN = findGlobals, envir = envir, ...,
                      tweak = tweak, dotdotdot = dotdotdot,
                      substitute = FALSE, unlist = FALSE)
    
    keep <- types <- NULL ## Not needed anymore
    
    debug && mdebug(" - preliminary globals found: [%d] %s",
                    length(globals), hpaste(sQuote(names(globals))))

    if (unlist) {
      needs_dotdotdot <- FALSE
      for (kk in seq_along(globals)) {
        s <- globals[[kk]]
        n <- length(s)
        if (identical(s[n], "...")) {
          needs_dotdotdot <- TRUE
          s <- s[-n]
          globals[[kk]] <- s
        }
      }
      globals <- unlist(globals, use.names = FALSE)
      if (length(globals) > 1L) globals <- unique(globals)
      if (needs_dotdotdot) globals <- c(globals, "...")
    }

    debug && mdebug(" - globals found: [%d] %s",
                    length(globals), hpaste(sQuote(globals)))
    debug && mdebug("findGlobals(..., dotdotdot = '%s', method = '%s', unlist = %s) ... DONE", dotdotdot, method, unlist) #nolint
    
    return(globals)
  }

  if (is.function(tweak)) {
    debug && mdebug(" - tweaking expression using function")
    expr <- tweak(expr)
  }

  if (method == "ordered") {
    find_globals_t <- find_globals_ordered
  } else if (method == "conservative") {
    find_globals_t <- find_globals_conservative
  } else if (method == "liberal") {
    find_globals_t <- find_globals_liberal
  }

  ## Is there a need for global '...' variables?
  needs_dotdotdot <- FALSE
  globals <- withCallingHandlers({
    oopts <- options(warn = 0L)
    on.exit(options(oopts))
    find_globals_t(expr, envir = envir, trace = trace)
  }, warning = function(w) {
    ## Warned about '...'?
    ## NOTE: The warning we're looking for is the one generated by
    ## codetools::findGlobals().  That warning is _not_ translated,
    ## meaning this approach should work as is as long as the message
    ## is not modified by codetools itself.  If codetools ever changes
    ## this such that the below string matching fails, then the package
    ## tests (tests/dotdotdot.R) will detect that.  In other words,
    ## such a change will not go unnoticed.  /HB 2017-03-08
    pattern <- "... may be used in an incorrect context"
    if (grepl(pattern, w$message, fixed = TRUE)) {
      debug && mdebug(" - detected: %s", dQuote(trim(w$message)))
      needs_dotdotdot <<- TRUE
      if (dotdotdot == "return") {
        ## Consume / muffle warning
        invokeRestart("muffleWarning")
      } else if (dotdotdot == "ignore") {
        needs_dotdotdot <<- FALSE
        ## Consume / muffle warning
        invokeRestart("muffleWarning")
      } else if (dotdotdot == "error") {
        e <- simpleError(w$message, w$call)
        stop(e)
      }
    }
  })

  if (needs_dotdotdot) globals <- c(globals, "...")

  debug && mdebug(" - globals found: [%d] %s", length(globals), hpaste(sQuote(globals)))
  debug && mdebug("findGlobals(..., dotdotdot = '%s', method = '%s', unlist = %s) ... DONE", dotdotdot, method, unlist) #nolint

  globals
}


## Utility functions adopted from codetools:::dropMissing()
## and codetools:::collectUsageFun()
drop_missing_formals <- function(x) {
  nx <- length(x)
  ix <- logical(length = nx)
  for (i in seq_len(nx)) {
    tmp <- x[[i]]
    if (!missing(tmp)) ix[i] <- TRUE
  }
  x[ix]
}

#' @importFrom codetools walkCode findLocalsList
collect_usage_function <- function(fun, name, w) {
  formals <- formals(fun)
  body <- body(fun)

  w$name <- c(w$name, name)
  parnames <- names(formals)

  formals_clean <- drop_missing_formals(formals)
  locals <- findLocalsList(c(list(body), formals_clean))

  w$env <- new.env(hash = TRUE, parent = w$env)
  for (n in c(parnames, locals)) assign(n, TRUE, w$env)
  for (a in formals_clean) walkCode(a, w)

  walkCode(body, w)
}


inject_tracer_to_function <- function(fcn, name) {
  b <- body(fcn)
  f <- formals(fcn)
  args <- setdiff(names(f), c("w", "..."))
  title <- sprintf("%s():", name)
  b <- bquote({
    message(.(title))
    if (length(.(args)) > 0) {
      mstr <- get("mstr", envir = getNamespace("globals"), mode = "function")
      mstr(mget(.(args)))
    }
    .(b)
  })
  body(fcn) <- b
  fcn
}

inject_tracer_to_walker <- function(w) {
  if (is.null(w$startCollectLocals)) {
    w$startCollectLocals <- function(parnames, locals, ...) { NULL }
  }
  if (is.null(w$finishCollectLocals)) {
    w$finishCollectLocals <- function(w, ...) { NULL }
  }
  if (is.null(w$enterInternal)) {
    w$enterInternal <- function(type, v, e, ...) { NULL }
  }
  
  for (key in names(w)) {
    fcn <- w[[key]] 
    if (!is.function(fcn)) next
    fcn <- inject_tracer_to_function(fcn, key)
    w[[key]] <- fcn
  }
  
  w
}
