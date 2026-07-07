# One-Command Report Generation
#
# Ported from Python normet report.py
# Renders a single self-contained HTML or Markdown report from an
# `nm_run` object (see nm_make_run / nm_save_run / nm_load_run in
# nm_utils_provenance.r): an auto-selected plot, a preview of the result
# table, the model summary, and the full provenance metadata.

NULL

.nm_html_escape <- function(x) {
  x <- as.character(x)
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub('"', "&quot;", x, fixed = TRUE)
  x <- gsub("'", "&#39;", x, fixed = TRUE)
  x
}

.nm_format_cell <- function(v) {
  if (length(v) == 0 || is.na(v)) return(NA_character_)
  if (is.numeric(v)) return(formatC(v, digits = 4, format = "g"))
  as.character(v)
}

.nm_meta_get <- function(meta, key) {
  val <- meta[[key]]
  if (is.null(val) || length(val) == 0) return("-")
  paste(as.character(val), collapse = ", ")
}

.nm_df_table_html <- function(df, max_rows = 12) {
  if (!is.data.frame(df) || nrow(df) == 0) return("<p><em>(empty)</em></p>")

  head_df <- utils::head(df, max_rows)
  cols <- colnames(head_df)

  header_html <- paste0("<th>", vapply(cols, .nm_html_escape, character(1)), "</th>", collapse = "")
  row_html <- vapply(seq_len(nrow(head_df)), function(i) {
    cells <- vapply(cols, function(col) {
      val <- .nm_format_cell(head_df[[col]][[i]])
      if (is.na(val)) val <- "&mdash;"
      .nm_html_escape(val)
    }, character(1))
    paste0("<tr>", paste0("<td>", cells, "</td>", collapse = ""), "</tr>")
  }, character(1))

  paste0(
    "<table class=\"nm-tbl\" border=\"0\">\n<thead><tr>", header_html, "</tr></thead>\n<tbody>\n",
    paste(row_html, collapse = "\n"), "\n</tbody>\n</table>"
  )
}

.nm_df_table_md <- function(df, max_rows = 12) {
  if (!is.data.frame(df) || nrow(df) == 0) return("*(empty)*")

  head_df <- utils::head(df, max_rows)
  cols <- colnames(head_df)

  header <- paste0("| ", paste(cols, collapse = " | "), " |")
  align <- paste0("| ", paste(rep("---", length(cols)), collapse = " | "), " |")
  rows <- vapply(seq_len(nrow(head_df)), function(i) {
    vals <- vapply(cols, function(col) {
      val <- .nm_format_cell(head_df[[col]][[i]])
      if (is.na(val)) "NA" else val
    }, character(1))
    paste0("| ", paste(vals, collapse = " | "), " |")
  }, character(1))

  paste(c(header, align, rows), collapse = "\n")
}

.nm_json_pre <- function(obj) {
  s <- tryCatch(
    as.character(jsonlite::toJSON(.coerce_json_safe(obj), pretty = TRUE, auto_unbox = TRUE)),
    error = function(e) paste(utils::capture.output(print(obj)), collapse = "\n")
  )
  paste0("<pre class=\"nm-meta\">", .nm_html_escape(s), "</pre>")
}

.nm_fig_to_b64 <- function(plot_obj, width = 10, height = 6, dpi = 110) {
  nm_require("base64enc", hint = "install.packages('base64enc')")
  tmp <- tempfile(fileext = ".png")
  on.exit(unlink(tmp), add = TRUE)
  ggplot2::ggsave(tmp, plot = plot_obj, width = width, height = height, dpi = dpi, bg = "white")
  raw <- readBin(tmp, what = "raw", n = file.info(tmp)$size)
  paste0("data:image/png;base64,", base64enc::base64encode(raw))
}

# Pick a sensible default plot for an nm_run, based on the columns present
# in run$result. Returns NULL (rather than erroring) if nothing matches or
# the chosen plotting function fails, so report generation never aborts.
.nm_auto_plot <- function(run) {
  res <- run$result
  if (!is.data.frame(res) || nrow(res) == 0) return(NULL)

  meta <- run$metadata %||% list()
  kind <- tolower(meta$kind %||% "")
  cols <- colnames(res)

  tryCatch({
    if (all(c("observed", "normalised") %in% cols)) {
      q_cols <- cols[grepl("^q[0-9.]+$", cols)]
      ci_low <- NULL
      ci_high <- NULL
      if (length(q_cols) >= 2) {
        q_vals <- suppressWarnings(as.numeric(sub("^q", "", q_cols)))
        if (!anyNA(q_vals)) {
          q_sorted <- q_cols[order(q_vals)]
          ci_low <- q_sorted[1]
          ci_high <- q_sorted[length(q_sorted)]
        }
      }
      nm_plot_normalise(res,
        observed_col = "observed", normalised_col = "normalised",
        ci_low = ci_low, ci_high = ci_high,
        title = if (nzchar(kind)) kind else "normalised series", ylabel = "value"
      )

    } else if (all(c("observed", "synthetic", "effect") %in% cols)) {
      cutoff <- meta$config$cutoff_date
      if (is.null(cutoff)) return(NULL)
      if ("synthetic_low" %in% cols) {
        nm_plot_bayesian_scm(res, cutoff_date = as.character(cutoff),
          title = if (nzchar(kind)) kind else "Bayesian SCM")
      } else {
        nm_plot_scm_dashboard(res, cutoff_date = as.character(cutoff),
          title = if (nzchar(kind)) kind else "SCM")
      }

    } else if ("observed" %in% cols &&
               length(setdiff(cols, c("observed", "model_pred", "residual", "base"))) >= 2) {
      nm_plot_decomposition_stack(res, observed_col = "observed",
        title = if (nzchar(kind)) kind else "decomposition")

    } else if (all(c("fold", "RMSE") %in% cols) || all(c("fold", "r") %in% cols)) {
      metric <- if ("RMSE" %in% cols) "RMSE" else "r"
      ggplot2::ggplot(res, ggplot2::aes(x = !!rlang::sym("fold"), y = !!rlang::sym(metric))) +
        ggplot2::geom_col(fill = "#1f77b4") +
        ggplot2::labs(title = "Walk-forward CV scores", x = "fold", y = metric) +
        ggplot2::theme_minimal()

    } else {
      NULL
    }
  }, error = function(e) {
    nm_get_logger("report")$debug("auto_plot failed: %s", conditionMessage(e))
    NULL
  })
}

.NM_REPORT_CSS <- "
body { font-family: -apple-system, system-ui, sans-serif; max-width: 1100px;
       margin: 2rem auto; padding: 0 1rem; color: #222; }
h1, h2 { border-bottom: 1px solid #ddd; padding-bottom: .3rem; }
h1 { font-size: 1.6rem; }
h2 { font-size: 1.2rem; margin-top: 2.2rem; }
dl.kv { display: grid; grid-template-columns: 12rem 1fr; gap: .25rem 1rem; font-size: .9rem; }
dl.kv dt { color: #888; }
dl.kv dd { margin: 0; font-family: ui-monospace, monospace; }
pre.nm-meta { background: #f7f7f8; padding: .8rem; border-radius: 4px;
              overflow-x: auto; font-size: .8rem; line-height: 1.4; }
table.nm-tbl { border-collapse: collapse; font-size: .85rem; }
table.nm-tbl th, table.nm-tbl td { padding: .25rem .6rem; text-align: right; }
table.nm-tbl th { background: #f0f0f2; border-bottom: 1px solid #ccc; }
table.nm-tbl tr:nth-child(even) { background: #fafafa; }
img.nm-plot { max-width: 100%; border: 1px solid #eee; padding: 6px; background: #fff; margin-top: .6rem; }
footer { margin-top: 3rem; color: #888; font-size: .8rem; border-top: 1px solid #eee; padding-top: .6rem; }
"

.NM_REPORT_KV_KEYS <- c("kind", "normet_version", "r_version", "platform", "host", "user",
  "timestamp", "seed", "data_hash", "config_hash")

#' Generate an HTML Report
#'
#' Render a single self-contained HTML report for an \code{nm_run} object:
#' an auto-selected, embedded base64-encoded PNG plot, a preview of the
#' result table, the model summary, and the full provenance metadata. The
#' output has no external JS or CSS dependencies.
#'
#' @param run An \code{nm_run} object (see \code{\link{nm_make_run}},
#'        typically loaded with \code{\link{nm_load_run}}).
#' @param out_path Character. Destination \code{.html} file. Its parent
#'        directory is created if missing.
#' @param title Character. Report title. Defaults to
#'        \code{"normet run report - <kind>"}.
#' @param extra_plots List of ggplot2/patchwork objects to embed below the
#'        auto-selected plot.
#'
#' @return Invisibly, \code{out_path}.
#' @export
nm_generate_html <- function(run, out_path, title = NULL, extra_plots = NULL) {
  if (!inherits(run, "nm_run")) stop("`run` must be an 'nm_run' object (see nm_make_run()).")
  log <- nm_get_logger("report")

  out_dir <- dirname(out_path)
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  meta <- run$metadata %||% list()
  kind <- meta$kind %||% "run"
  title <- title %||% paste0("normet run report - ", kind)

  kv_rows <- paste(vapply(.NM_REPORT_KV_KEYS, function(k) {
    sprintf("<dt>%s</dt><dd>%s</dd>", .nm_html_escape(k), .nm_html_escape(.nm_meta_get(meta, k)))
  }, character(1)), collapse = "\n")

  fig <- .nm_auto_plot(run)
  plot_parts <- character(0)
  if (!is.null(fig)) {
    plot_parts <- c(plot_parts, sprintf('<img class="nm-plot" src="%s" alt="auto plot">', .nm_fig_to_b64(fig)))
  }
  for (extra in extra_plots %||% list()) {
    b64 <- tryCatch(.nm_fig_to_b64(extra), error = function(e) {
      log$warn("extra plot serialisation failed: %s", conditionMessage(e))
      NULL
    })
    if (!is.null(b64)) {
      plot_parts <- c(plot_parts, sprintf('<img class="nm-plot" src="%s" alt="user plot">', b64))
    }
  }
  plot_block <- if (length(plot_parts) > 0) paste(plot_parts, collapse = "\n") else "<p><em>No plot available.</em></p>"

  table_block <- .nm_df_table_html(run$result)
  meta_block <- .nm_json_pre(meta)

  model_block <- ""
  if (!is.null(run$model)) {
    model_type <- class(run$model)[1]
    backend <- attr(run$model, "backend") %||% "-"
    model_block <- paste0(
      "\n<h2>Model</h2>\n<dl class=\"kv\">\n",
      sprintf("<dt>type</dt><dd>%s</dd>\n", .nm_html_escape(model_type)),
      sprintf("<dt>backend</dt><dd>%s</dd>\n", .nm_html_escape(as.character(backend))),
      "</dl>\n"
    )
  }

  generated_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  body <- paste0(
    "<!doctype html>\n",
    "<html lang=\"en\"><head>\n",
    "<meta charset=\"utf-8\">\n",
    "<title>", .nm_html_escape(title), "</title>\n",
    "<style>", .NM_REPORT_CSS, "</style>\n",
    "</head><body>\n\n",
    "<h1>", .nm_html_escape(title), "</h1>\n",
    "<dl class=\"kv\">\n", kv_rows, "\n</dl>\n\n",
    "<h2>Plot</h2>\n", plot_block, "\n\n",
    "<h2>Result preview</h2>\n", table_block, "\n\n",
    "<h2>Provenance</h2>\n", meta_block, "\n",
    model_block, "\n",
    "<footer>Generated by normet on ", generated_at, ".</footer>\n\n",
    "</body></html>\n"
  )

  writeLines(body, out_path, useBytes = TRUE)
  log$info("HTML report -> %s (%.1f KB)", out_path, file.info(out_path)$size / 1024)
  invisible(out_path)
}

#' Generate a Markdown Report
#'
#' Render a single-file plain-text Markdown report for an \code{nm_run}
#' object: a metadata overview, a preview of the result table, the model
#' summary, and the full provenance metadata as a JSON code block.
#'
#' @inheritParams nm_generate_html
#'
#' @return Invisibly, \code{out_path}.
#' @export
nm_report_to_markdown <- function(run, out_path, title = NULL) {
  if (!inherits(run, "nm_run")) stop("`run` must be an 'nm_run' object (see nm_make_run()).")
  log <- nm_get_logger("report")

  out_dir <- dirname(out_path)
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  meta <- run$metadata %||% list()
  kind <- meta$kind %||% "run"
  title <- title %||% paste0("normet report - ", kind)

  lines <- c(paste0("# ", title), "")

  for (k in .NM_REPORT_KV_KEYS) {
    lines <- c(lines, sprintf("- **%s**: `%s`", k, .nm_meta_get(meta, k)))
  }
  lines <- c(lines, "")

  lines <- c(lines, "## Result Preview", "", .nm_df_table_md(run$result), "")

  if (!is.null(run$model)) {
    model_type <- class(run$model)[1]
    backend <- attr(run$model, "backend") %||% "-"
    lines <- c(lines, "## Model Summary", "",
      sprintf("- **type**: `%s`", model_type),
      sprintf("- **backend**: `%s`", as.character(backend)),
      "")
  }

  json_str <- tryCatch(
    as.character(jsonlite::toJSON(.coerce_json_safe(meta), pretty = TRUE, auto_unbox = TRUE)),
    error = function(e) paste(utils::capture.output(print(meta)), collapse = "\n")
  )
  lines <- c(lines, "## Full Provenance Metadata", "", "```json", json_str, "```", "")

  generated_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  lines <- c(lines, sprintf("Generated by normet on %s.", generated_at))

  writeLines(paste(lines, collapse = "\n"), out_path, useBytes = TRUE)
  log$info("Markdown report -> %s (%.1f KB)", out_path, file.info(out_path)$size / 1024)
  invisible(out_path)
}
