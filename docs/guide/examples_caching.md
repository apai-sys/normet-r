# Caching and provenance

The snippets continue from the quick start: `my1` is the bundled record, and
`predictors`/`met_vars` are the covariate lists used there.

## Opt-in disk cache

The pipelines accept a `cache_dir`: a hit on a matching cache key skips
training and normalisation entirely. The key is built from the configuration,
the data's content hash and the model's fingerprint, so a re-fitted model — or
changed data — invalidates it correctly.

```r
library(normet)

cache <- nm_make_cache(".normet_cache")     # creates the directory

results <- nm_do_all(
  df            = my1,
  target        = "NO2",
  covariates    = predictors,
  resample_vars = met_vars,
  n_samples     = 300,
  cache_dir     = cache$path
)
# The same call again returns at once, from .normet_cache/<key>.rds
```

`nm_normalise()`, `nm_train_model()`, `nm_decompose()` and the multi-site
drivers take the same argument. This matters most for decomposition, which
calls `nm_normalise()` once per fixed time-variable/meteorological feature,
each a full Monte Carlo resample-and-predict over `n_samples` draws.

For your own expensive steps, derive the same deterministic keys without
serialising the data into them:

```r
key  <- nm_config_hash(nm_dataframe_hash(df_prep), n_samples = 300)
path <- file.path(cache$path, paste0(key, ".rds"))

if (file.exists(path)) {
  result <- readRDS(path)
} else {
  result <- my_slow_function(df_prep)
  saveRDS(result, path)
}
```

`nm_make_cache()` also returns `memoise`, a function that memoises a callable
onto the same directory, when the `memoise` package is available.

## Run archives

For reproducibility, wrap a result with provenance metadata and save it:

```r
results <- nm_do_all(df = my1, target = "NO2", covariates = predictors,
                     resample_vars = met_vars, n_samples = 300)

run <- nm_make_run(
  result  = results$res,
  kind    = "do_all",
  config  = list(target = "NO2", backend = "lightgbm"),
  df      = my1,
  df_prep = results$df_prep,
  model   = results$model,
  seed    = 7654321
)

saved <- nm_save_run(run, "runs/my1_run")
# writes runs/my1_run.rds (artifact, saveRDS)
#    and runs/my1_run.meta.json (sidecar metadata)

# Later, in a clean session:
back <- nm_load_run("runs/my1_run")   # the .rds suffix is added if absent
back$metadata
head(back$result)
```

The JSON sidecar contains the R and package versions, the platform and host,
the timestamp, the seed, the data hash and shape (when `df` is given), the
config and its hash (when `config` is given), and `extra` (free-form).

## Reports

```r
nm_generate_html(run, "report.html")             # English
nm_generate_html(run, "report_zh.html", lang = "zh")
nm_report_to_markdown(run, "report.md")
```

`nm_generate_html()` writes a single self-contained HTML report: an
auto-selected, embedded PNG figure, a preview of the result table, the model
summary and the full provenance record — with no external JS or CSS
dependencies. `lang = "zh"` renders its headings, labels and figure texts in
Chinese. `nm_report_to_markdown()` writes the same content as plain-text
Markdown.
