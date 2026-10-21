# normet as an MCP server, over stdio
#
# Ported from Python normet mcp_server.py (normet-mcp): the same tools, prompts and
# resources, by the same names, served by R with no SDK -- MCP's JSON-RPC, one
# message a line on stdin and stdout.

NULL

.NM_MCP_INSTRUCTIONS <- paste(
  "normet removes the effect of weather from air-quality time series (meteorological",
  "normalisation, or de-weathering) and estimates the effect of interventions with",
  "synthetic control. This is normet's R package.",
  "",
  "Work as an analyst's assistant, in this order: look at the data (normet_inspect_data,",
  "with the target), train a model and normalise (normet_start_do_all), read how well the",
  "model predicts the held-out rows and what the normalised series shows (normet_job_status",
  "once the job is done, or normet_read_run), then decompose (normet_start_decompose) or,",
  "for a panel of sites and an intervention date, run a synthetic control (normet_start_scm).",
  "",
  "Jobs return an id at once; ask normet_job_status until the job has ended. A job is an R",
  "script (job.R in its folder), which runs again as it is.",
  "",
  "Where you help most is choosing what to model and judging the result. Recommend, with",
  "your reasons and how sure you are; the user decides.",
  "- The predictors: propose the target and the meteorological covariates from the table's",
  "  readings (roles, missing values, correlation with the target), say what you left out",
  "  and why, and ask the user to confirm before starting a job.",
  "- The model: judge it on the 'testing' rows (R2, RMSE, FAC2); say plainly where it is",
  "  weak, and what would test it further (normet_start_cv).",
  "- The result: describe what the normalised series and its meteorological part show,",
  "  by year or month as the reading gives them; do not claim a trend or a cause the",
  "  numbers do not show.",
  "- A synthetic control: propose the treated unit, the cutoff and the donor pool; judge",
  "  the pre-period fit before reading the effect.",
  "Quote normet's numbers as the tools give them; do not compute or invent others.",
  sep = "\n"
)

.NM_MCP_WORKFLOW <- paste(
  "De-weathering %s with normet:",
  "",
  "1. normet_inspect_data with the target: the table's span and step, gaps, each column's",
  "   role, missing values and correlation with the target. PROPOSE the covariates",
  "   (meteorological columns) with your reasons; ask the user to confirm.",
  "2. normet_start_do_all with the confirmed target and covariates. Watch it with",
  "   normet_job_status.",
  "3. Read the model's fit on the 'testing' rows and the normalised series' means by year or",
  "   month. Say what they show and where the model is weak. normet_figure draws them.",
  "4. If the user wants the change split by time scale or by meteorological variable,",
  "   normet_start_decompose (method 'emission' or 'meteorology').",
  "5. normet_write_report for the run.",
  "",
  "Quote numbers only as the tools give them.",
  sep = "\n"
)

#' The protocol versions this server speaks, newest first.
#' @noRd
.NM_MCP_VERSIONS <- c("2025-06-18", "2025-03-26", "2024-11-05")

.nm_obj <- function(x = list()) if (length(x)) x else structure(list(), names = character())

.p_str <- function(d) list(type = "string", description = d)
.p_strs <- function(d) list(type = "array", items = list(type = "string"), description = d)
.p_int <- function(d) list(type = "integer", description = d)
.p_num <- function(d) list(type = "number", description = d)

.nm_tool <- function(name, description, fn, properties = list(), required = character()) {
  list(name = name, description = description, fn = fn,
       schema = list(type = "object", properties = .nm_obj(properties), required = I(required)))
}

#' normet's tools: name, description, input schema and what each calls.
#' @noRd
.nm_mcp_tools <- function() {
  data_props <- list(
    example = .p_str("An example's name (normet_list_examples)."),
    data = .p_str("Path of a CSV/Parquet/Feather table with a 'date' column.")
  )
  label <- list(label = .p_str("A label to know the job by."))
  list(
    .nm_tool("normet_list_examples",
             "The example tables normet ships, with what each is for. Give a tool example=<name> to use one.",
             .nm_agent_list_examples),
    .nm_tool("normet_inspect_data", paste(
      "A table before anything is fitted: rows and columns, the dates' span, usual step and",
      "missing timestamps, whether it is a panel of units, and each numeric column's role",
      "(pollutant, met, other -- read from its name), missing values, range and, with",
      "target=<column>, its correlation with the target. Give example=<name> or data=<path of",
      "a CSV/Parquet/Feather table with a 'date' column>."
    ), .nm_agent_inspect_data, c(data_props, list(target = .p_str("The column to be modelled.")))),
    .nm_tool("normet_start_do_all", paste(
      "Start a job: train a model of `target` on `covariates` (the user's choice; normet adds",
      "the time features itself) and normalise it by resampling the meteorology",
      "(`resample_vars`, all covariates by default) n_samples times (normet's default 300).",
      "backend: 'lightgbm' (the default) or 'h2o' (H2O AutoML; needs Java); split_method:",
      "'random', 'ts', 'month_ts', 'season_ts'; train_fraction: share of rows trained on",
      "(0.75). Writes normalised.csv and the run (run.rds, its model in run_model/); poll",
      "normet_job_status, which reads them once done."
    ), .nm_agent_start_do_all, c(list(
      target = .p_str("The column to model."),
      covariates = .p_strs("The predictor columns (meteorology).")
    ), data_props, list(
      resample_vars = .p_strs("The covariates resampled to normalise (all by default)."),
      backend = .p_str("'lightgbm' or 'h2o'."),
      n_samples = .p_int("Resamples of the meteorology (300)."),
      split_method = .p_str("'random', 'ts', 'month_ts' or 'season_ts'."),
      train_fraction = .p_num("Share of rows trained on (0.75)."),
      seed = .p_int("Random seed.")
    ), label), c("target", "covariates")),
    .nm_tool("normet_start_decompose", paste(
      "Start a job: decompose `target`. method 'emission' splits the normalised series into",
      "time scales (trend, seasonal, weekly, diurnal); 'meteorology' splits observed -",
      "normalised into each meteorological variable's part. Trains its own model on",
      "`covariates`. Writes decomposition.csv; poll normet_job_status."
    ), .nm_agent_start_decompose, c(list(
      target = .p_str("The column to model."),
      covariates = .p_strs("The predictor columns (meteorology)."),
      method = .p_str("'emission' (default) or 'meteorology'.")
    ), data_props, list(
      backend = .p_str("'lightgbm' or 'h2o'."),
      n_samples = .p_int("Resamples of the meteorology."),
      seed = .p_int("Random seed.")
    ), label), c("target", "covariates")),
    .nm_tool("normet_start_scm", paste(
      "Start a job: a synthetic control of the `treated` unit from the donor pool (`donors`,",
      "every other unit by default) in a panel (one row per unit and date: date_col 'date',",
      "unit_col 'ID', outcome_col 'value' by default; the scm example uses unit_col='code',",
      "outcome_col='NO2_dw'), and its effect after `cutoff` (YYYY-MM-DD). backend: 'scm',",
      "'mlscm', 'abadie', 'robust', 'did', 'mcnnm'. Writes scm.csv; poll normet_job_status,",
      "which reads the pre-period fit and the effect."
    ), .nm_agent_start_scm, c(list(
      treated = .p_str("The treated unit."),
      cutoff = .p_str("The intervention date, YYYY-MM-DD.")
    ), data_props, list(
      donors = .p_strs("The donor units (every other unit by default)."),
      date_col = .p_str("The date column ('date')."),
      unit_col = .p_str("The unit column ('ID')."),
      outcome_col = .p_str("The outcome column ('value')."),
      backend = .p_str("'scm', 'mlscm', 'abadie', 'robust', 'did' or 'mcnnm'.")
    ), label), c("treated", "cutoff")),
    .nm_tool("normet_start_cv", paste(
      "Start a job: time-series cross-validation of a model of `target` on `covariates` --",
      "trained on the past, scored on the next block, n_splits times (5), `gap` rows between",
      "them. Writes cv.csv; poll normet_job_status."
    ), .nm_agent_start_cv, c(list(
      target = .p_str("The column to model."),
      covariates = .p_strs("The predictor columns (meteorology).")
    ), data_props, list(
      n_splits = .p_int("Folds (5)."),
      gap = .p_int("Rows between the training rows and the scored block (0)."),
      backend = .p_str("'lightgbm' or 'h2o'.")
    ), label), c("target", "covariates")),
    .nm_tool("normet_job_status", paste(
      "Where a job is (queued, running, done, failed, cancelled). Once done: the files it",
      "wrote and normet's readings of them -- for do-all, the model's fit on the training and",
      "held-out rows, its feature importance and the normalised series' means by year or",
      "month. Jobs run one at a time, in the order started."
    ), .nm_agent_job_status, list(job_id = .p_str("The job's id.")), "job_id"),
    .nm_tool("normet_cancel_job", "Stop a job: one waiting never starts, one running is stopped.",
             .nm_agent_cancel_job, list(job_id = .p_str("The job's id.")), "job_id"),
    .nm_tool("normet_list_jobs", "The latest jobs, newest first: id, kind, state, label or command.",
             .nm_agent_list_jobs, list(limit = .p_int("How many (20)."))),
    .nm_tool("normet_read_run", paste(
      "A saved do-all run (its run.rds): what it was asked, the model's fit (nm_modStats on",
      "the training, held-out and all rows), its feature importance and the normalised series",
      "against the observed."
    ), .nm_agent_read_run, list(run = .p_str("Path of the run (run.rds).")), "run"),
    .nm_tool("normet_read_result", paste(
      "A result table read as `kind` says: 'normalised' (observed and normalised columns),",
      "'decomposition', 'scm' (with the `cutoff` it was run with) or 'cv'."
    ), .nm_agent_read_result, list(
      path = .p_str("Path of the table."),
      kind = .p_str("'normalised', 'decomposition', 'scm' or 'cv'."),
      cutoff = .p_str("An SCM result's cutoff, YYYY-MM-DD.")
    ), c("path", "kind")),
    .nm_tool("normet_figure", paste0(
      "One of normet's figures, as an image, of a run (run.rds) or a result table. kind: ",
      paste(sprintf("%s (%s)", names(.NM_AGENT_FIGURES), .NM_AGENT_FIGURES), collapse = "; "), "."
    ), .nm_agent_figure, list(
      source = .p_str("A run (run.rds) or a result table."),
      kind = .p_str(paste(names(.NM_AGENT_FIGURES), collapse = ", ")),
      cutoff = .p_str("An SCM result's cutoff, YYYY-MM-DD."),
      dpi = .p_int("Resolution (at least 150).")
    ), c("source", "kind")),
    .nm_tool("normet_write_report",
             "The HTML report of a saved do-all run, with its provenance: written beside the run, or to `out`.",
             .nm_agent_write_report, list(
               run = .p_str("Path of the run (run.rds)."),
               out = .p_str("Where to write the report.")
             ), "run")
  )
}

#' Call one of normet's tools, as an assistant does
#'
#' The tools \code{\link{nm_mcp_server}} serves, called in this R session: what the
#' R GUI's Assistant asks of normet. A job's tool writes an R script and starts it in
#' an R process of its own, returning at once.
#'
#' @param name The tool's name, e.g. \code{"normet_inspect_data"}.
#' @param args A named list of its arguments.
#' @param home Where jobs are kept: \code{$NORMET_MCP_HOME}, or
#'   \code{~/.normet/mcp-r}.
#' @param roots The folders files may be read and written in:
#'   \code{$NORMET_MCP_ROOTS}, or the home folder.
#' @return A list: \code{text}, what the tool says (normet's readings), and for a
#'   figure \code{png}, its bytes.
#' @seealso \code{\link{nm_mcp_server}}
#' @examples
#' cat(nm_agent_tool("normet_list_examples", home = tempfile("normet-mcp-"))$text)
#' @export
nm_agent_tool <- function(name, args = list(), home = NULL, roots = NULL) {
  .nm_mcp_call(.nm_agent(home, roots), name, args)
}

.nm_mcp_call <- function(agent, name, args) {
  tools <- .nm_mcp_tools()
  tool <- Filter(function(t) identical(t$name, name), tools)
  if (!length(tool)) stop(sprintf("no tool '%s'", name), call. = FALSE)
  fn <- tool[[1]]$fn
  args <- args %||% list()
  args <- args[intersect(names(args), names(formals(fn)))]
  args <- lapply(args, function(a) if (is.list(a)) unlist(a) else a)
  value <- do.call(fn, c(list(agent), args))
  if (is.list(value)) list(text = value$caption, png = value$png) else list(text = value, png = NULL)
}

.nm_mcp_result <- function(id, result) list(jsonrpc = "2.0", id = id, result = result)
.nm_mcp_error <- function(id, code, message) {
  list(jsonrpc = "2.0", id = id, error = list(code = code, message = message))
}

#' One message answered: the reply, or NULL for a notification.
#' @noRd
.nm_mcp_handle <- function(msg, agent) {
  id <- msg$id
  method <- msg$method %||% ""
  params <- msg$params %||% list()
  if (is.null(id)) return(NULL)  # a notification: nothing is said back
  if (method == "initialize") {
    asked <- params$protocolVersion %||% ""
    return(.nm_mcp_result(id, list(
      protocolVersion = if (asked %in% .NM_MCP_VERSIONS) asked else .NM_MCP_VERSIONS[1],
      capabilities = list(tools = .nm_obj(), resources = .nm_obj(), prompts = .nm_obj()),
      serverInfo = list(name = "normet", version = as.character(utils::packageVersion("normet"))),
      instructions = .NM_MCP_INSTRUCTIONS
    )))
  }
  if (method == "ping") return(.nm_mcp_result(id, .nm_obj()))
  if (method == "tools/list") {
    return(.nm_mcp_result(id, list(tools = lapply(.nm_mcp_tools(), function(t) {
      list(name = t$name, description = t$description, inputSchema = t$schema)
    }))))
  }
  if (method == "tools/call") {
    said <- tryCatch(.nm_mcp_call(agent, params$name %||% "", params$arguments),
                     error = function(e) e)
    if (inherits(said, "error")) {
      return(.nm_mcp_result(id, list(
        content = list(list(type = "text", text = conditionMessage(said))), isError = TRUE
      )))
    }
    content <- list(list(type = "text", text = said$text))
    if (!is.null(said$png)) {
      content <- c(content, list(list(type = "image", data = jsonlite::base64_enc(said$png),
                                      mimeType = "image/png")))
    }
    return(.nm_mcp_result(id, list(content = content, isError = FALSE)))
  }
  if (method == "resources/list") {
    return(.nm_mcp_result(id, list(resources = list(list(
      uri = "normet://examples", name = "examples", description = "normet's example tables",
      mimeType = "text/plain"
    )))))
  }
  if (method == "resources/templates/list") {
    return(.nm_mcp_result(id, list(resourceTemplates = list(list(
      uriTemplate = "normet://jobs/{job_id}/command", name = "job-command",
      description = "A job's R script (job.R), which runs again as it is from its folder",
      mimeType = "text/plain"
    )))))
  }
  if (method == "resources/read") {
    uri <- params$uri %||% ""
    text <- tryCatch({
      if (uri == "normet://examples") {
        .nm_agent_list_examples(agent)
      } else if (grepl("^normet://jobs/[^/]+/command$", uri)) {
        job_id <- sub("^normet://jobs/([^/]+)/command$", "\\1", uri)
        paste(readLines(file.path(.nm_job_folder(agent$store, job_id), "job.R"), warn = FALSE),
              collapse = "\n")
      } else {
        stop(sprintf("no resource %s", uri), call. = FALSE)
      }
    }, error = function(e) e)
    if (inherits(text, "error")) return(.nm_mcp_error(id, -32002, conditionMessage(text)))
    return(.nm_mcp_result(id, list(contents = list(list(uri = uri, mimeType = "text/plain", text = text)))))
  }
  if (method == "prompts/list") {
    return(.nm_mcp_result(id, list(prompts = list(list(
      name = "deweather_workflow",
      description = "De-weathering a pollutant's series, with the user choosing the predictors and judging the model",
      arguments = list(list(name = "data", description = "The table, as the user names it", required = FALSE))
    )))))
  }
  if (method == "prompts/get") {
    if (!identical(params$name, "deweather_workflow")) {
      return(.nm_mcp_error(id, -32602, sprintf("no prompt '%s'", params$name %||% "")))
    }
    what <- params$arguments$data %||% "the table given"
    return(.nm_mcp_result(id, list(
      description = "De-weathering a pollutant's series",
      messages = list(list(role = "user", content = list(type = "text", text = sprintf(.NM_MCP_WORKFLOW, what))))
    )))
  }
  .nm_mcp_error(id, -32601, sprintf("method not found: %s", method))
}

#' normet as an MCP server
#'
#' Serves normet's tools to an AI agent -- Claude Desktop, Claude Code or any other
#' MCP client -- over stdio on this machine, as normet-py's \code{normet-mcp} does:
#' the examples and a table's readings; do-all, decompose, SCM and cross-validation
#' started as jobs (each an R script, \code{job.R}, run by Rscript in a folder of its
#' own under \code{$NORMET_MCP_HOME}, \code{~/.normet/mcp-r} by default) and
#' watched, cancelled, read; a run's figures and report.
#'
#' The models are trained here and the tables stay here: a tool gives the model
#' normet's readings, small tables and figures -- never the data. Files are read and
#' written under \code{$NORMET_MCP_ROOTS} (folders separated as PATH separates them;
#' the home folder where unset). Register it with, for example:
#'
#' \preformatted{claude mcp add normet -- Rscript -e "normet::nm_mcp_server()"}
#'
#' It reads one JSON-RPC message a line until its input ends. What R prints while a
#' tool runs goes to stderr: stdout is the protocol's.
#'
#' @param home Where jobs are kept (see above).
#' @param roots The folders files may be read and written in (see above).
#' @param input,output The connections the protocol is read from and written to
#'   (stdin and stdout).
#' @return Invisibly \code{NULL}, once the input has ended.
#' @seealso \code{\link{nm_agent_tool}}
#' @export
nm_mcp_server <- function(home = NULL, roots = NULL, input = file("stdin"), output = stdout()) {
  agent <- .nm_agent(home, roots)
  if (!isOpen(input)) {
    open(input, "r")
    on.exit(close(input), add = TRUE)
  }
  send <- function(reply) {
    cat(jsonlite::toJSON(reply, auto_unbox = TRUE, null = "null", digits = NA), "\n",
        sep = "", file = output)
    flush(output)
  }
  repeat {
    line <- readLines(input, n = 1, warn = FALSE, encoding = "UTF-8")
    if (!length(line)) break
    if (!nzchar(trimws(line))) next
    msg <- tryCatch(jsonlite::fromJSON(line, simplifyVector = FALSE), error = function(e) NULL)
    if (!is.list(msg)) {
      send(.nm_mcp_error(NULL, -32700, "parse error"))
      next
    }
    # Whatever R prints while answering goes to stderr.
    sink(stderr())
    reply <- tryCatch(.nm_mcp_handle(msg, agent),
                      error = function(e) .nm_mcp_error(msg$id, -32603, conditionMessage(e)))
    sink()
    if (!is.null(reply)) send(reply)
  }
  invisible(NULL)
}
