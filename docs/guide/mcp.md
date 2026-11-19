# AI assistants (MCP server)

`normet`'s MCP server serves the package to an AI assistant over the Model
Context Protocol, so Claude Code, Claude Desktop or any other MCP client can
drive an analysis: look at a table, train and normalise, decompose, run a
synthetic control, read the results and draw them. The server is part of the R
package — no extra install beyond `normet` and R.

## Register the server

Claude Code:

```bash
claude mcp add normet -- Rscript -e "normet::nm_mcp_server()"
```

Claude Desktop (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "normet": {
      "command": "Rscript",
      "args": ["-e", "normet::nm_mcp_server()"]
    }
  }
}
```

The server reads one JSON-RPC message per line on stdin and writes the
protocol's answers to stdout; what R prints while a tool runs goes to stderr.

## What it serves

- **Readings, not data.** The assistant is given normet's readings of a table
  or a result as text — a model's `nm_modStats()` on the held-out rows, the
  normalised series' means by year or month, a synthetic control's pre-period
  fit and effect — plus figures. The models are trained here and the tables
  stay here. Files are read and written only under `$NORMET_MCP_ROOTS`
  (folders separated as `PATH` separates them; the home folder when unset).
- **Jobs.** Each fit is an R script (`job.R`) run by `Rscript` in a folder of
  its own under `$NORMET_MCP_HOME` (`mcp-r` under
  `tools::R_user_dir("normet", "data")` by default). The script
  is the job's record and runs again as it is, without the assistant; jobs are
  watched (`normet_job_status`) and can be cancelled (`normet_cancel_job`).
- **The same steps as the window.** The tools cover the examples and a table's
  readings; do-all, decompose, SCM (fit, all-units, staggered), placebo-in-
  space/time, uncertainty bands, leave-one-donor-out stability, multi-site
  do-all and decomposition, decomposition uncertainty and cross-validation
  (each started as a job); trend and segmented-trend analyses; SCM
  diagnostics, pre-trend, conformal interval, effect bands; a run's figures
  and report (`normet_trend`, `normet_trend_breaks`, `normet_scm_diagnostics`,
  `normet_pre_trend_test`, `normet_conformal_interval`,
  `normet_effect_bands_space`, `normet_effect_bands_time`, ...).
- **You decide.** The server tells the assistant to propose the target, the
  predictors and the donor pool with its reasons, to let you confirm them, and
  to quote only the numbers the tools return.

The desktop app's **Assistant** panel uses these same tools; see
[Desktop GUI](gui.md).

## Calling a tool yourself

`nm_agent_tool()` calls one of the tools in the current R session — useful for
seeing exactly what an assistant receives:

```r
cat(nm_agent_tool("normet_list_examples", home = tempfile("normet-mcp-"))$text)
```

It returns a list with `text` (the tool's reading) and, for a figure tool,
`png` (the image bytes).

## Relation to normet-py

The Python package's `normet-mcp` offers the same design over its CLI. Here
each job is plain Rscript, so there is no separate binary to install; the
`gui/` window bundles the same server for its own Assistant, with a
per-window token.
