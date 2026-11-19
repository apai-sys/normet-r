# Roadmap

`normet` (R) is at version **1.0.0**. 1.0 was about *hardening* rather than
adding features, and it commits the package to API stability for downstream
users.

## What 1.0 means

- **Public API is stable.** Anything exported from the package — the `nm_*`
  functions and datasets — follows [Semantic Versioning](https://semver.org).
  Breaking changes require a major version bump and a deprecation window of at
  least one minor release.
- **Internal functions** (leading-dot helpers and other non-exported code) are
  explicitly *not* part of the contract.
- **Optional dependencies** stay optional: `library(normet)` never requires
  `lightgbm`, `h2o`, `arrow`, `readxl`, `ecmwfr`, `sf`, `memuse`,
  `patchwork`, `forecast` or `solitude`.

## Shipped

| Status | Item |
|:------:|------|
| ✅ | Core normalisation / decomposition / SCM pipelines |
| ✅ | Walk-forward CV and per-fold diagnostics (`nm_cv_score`) |
| ✅ | Multiple SCM backends (`scm`, `abadie`, `did`, `mcnnm`, `robust`, `mlscm`, `bayesian`) + diagnostics + inference |
| ✅ | Multi-site batch drivers (`nm_do_all_multisite`, `nm_decompose_multisite`, `nm_multisite_apply`) |
| ✅ | Provenance archives (`nm_make_run` / `nm_save_run` / `nm_load_run`) |
| ✅ | HTML and Markdown run reports in English and Chinese |
| ✅ | Real-world data adapters (OpenAQ / ERA5 / EEA / UK networks / Open-Meteo) and HYSPLIT trajectory features |
| ✅ | Plotting suite (polar / PDP grid / decomposition stack / SCM dashboard / cycles) |
| ✅ | Bayesian SCM with Dirichlet weights and credible bands |
| ✅ | Trend statistics (`nm_trend`, `nm_mann_kendall`, `nm_theil_sen`) and the segmented fit `nm_trend_breaks` |
| ✅ | Uncertainty attribution (`nm_decompose_uncertainty`) — spread split into weather vs model form |
| ✅ | Log-scale fits (`log_transform`: train on `log1p`, report in original units) |
| ✅ | Event detection (`nm_detect_events`) and anomaly scores (`nm_anomaly_scores`) |
| ✅ | SCM pre-trend test and event-study figure; donor-spatial diagnostics |
| ✅ | Staggered adoption (`nm_run_scm_staggered`) with per-unit placebo p-values and the cross-unit permutation test |
| ✅ | Qt desktop GUI (`gui/`) driving the R package, with packaged installers |
| ✅ | MCP server (`nm_mcp_server`) and the R GUI's Assistant |
| ✅ | pkgdown configuration and vignette articles |

## Open

| Status | Item |
|:------:|------|
| 📋 | China data adapters — scoped as an issue and data-format note; data licences and station coordinates first |
| 📋 | A CRAN submission pass (the package currently installs from GitHub) |
| 📋 | Device passthrough where the backend supports one (H2O's cluster controls already pass through `n_cores` / `max_mem_size`) |

## Deprecation policy

In force. It covers the public API — every exported `nm_*` function and the
datasets — and nothing else.

- A symbol marked for removal will:
  1. Emit a lifecycle warning for at least one minor release.
  2. Be documented as deprecated in its help page and in `NEWS.md`.
  3. Have a replacement linked from the warning message.
- Symbols are only removed in a major release.
- A symbol that has never appeared in a release is not covered and may be
  changed or withdrawn outright.

Nothing has been deprecated under this policy so far, so no removal is due.

## Out of scope

- A web dashboard. The desktop GUI covers the no-code workflow; a hosted
  equivalent is a separate project, and community-contributed examples are
  welcome but not part of the package proper.
- The Python-only paths of `normet-py` (the Chronos-2 foundation model and the
  command-line tool) are not roadmap items here; the R package focuses on the
  normalisation, decomposition and causal-inference core, with the GUI and MCP
  server as its interfaces.
