#!/bin/bash --login
#SBATCH -p multicore
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:30:00
#SBATCH --mem=8G
#SBATCH -o /net/scratch/n94921cs/normet-r/vignettes/%j_render_vignette.out
#SBATCH -e /net/scratch/n94921cs/normet-r/vignettes/%j_render_vignette.err

# Render vignettes/normet.Rmd in place to verify it still builds after the
# full-API target/covariates/dropna/train_fraction rename. lightgbm is not
# installed in the rnormet env, so the model-training/normalise/decompose/
# rolling/pdp/do_all chunks (all gated on
# eval = requireNamespace("lightgbm", quietly = TRUE)) will be skipped with
# their informational note rather than executed -- the always-evaluated
# chunks (dataset overview, HYSPLIT parsing, SCM section) still exercise the
# renamed API (e.g. nm_run_scm's target= arg to nm_plot_time_series).
set -euo pipefail
module purge; unset LD_LIBRARY_PATH PYTHONPATH PYTHONHOME
module load apps/binapps/anaconda3/2024.10
export LD_LIBRARY_PATH="/usr/lib64:/lib64:${LD_LIBRARY_PATH:-}"
source activate rnormet
cd /net/scratch/n94921cs/normet-r

# The working tree (uncommitted rename) isn't installed into the rnormet env
# yet -- the vignette's `library(normet)` needs an actual install, not just
# devtools::load_all(). Install the current working copy first.
Rscript -e 'devtools::install(pkg = ".", dependencies = FALSE, upgrade = FALSE, quiet = TRUE, build_vignettes = FALSE)'
echo "=== normet package (re)installed from working tree ==="

Rscript -e 'rmarkdown::render("vignettes/normet.Rmd", output_dir = "vignettes")'
echo "=== normet.Rmd rendered ==="
ls -la vignettes/normet.html
