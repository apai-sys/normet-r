#!/bin/bash --login
#SBATCH -p multicore
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=00:30:00
#SBATCH --mem=8G
#SBATCH -o /net/scratch/n94921cs/normet-r/ci_check_%j.out
#SBATCH -e /net/scratch/n94921cs/normet-r/ci_check_%j.err

# Reproduce the GitHub Actions R-CMD-check workflow locally (rcmdcheck::rcmdcheck
# with error_on = "warning", matching r-lib/actions/check-r-package@v2's default
# strictness), after the target/covariates/dropna/train_fraction rename.
#
# NOTE on _R_CHECK_FORCE_SUGGESTS_: several Suggests packages (ecmwfr, forecast,
# h2o, lightgbm, memuse, patchwork, sf, solitude) are not installed in the
# rnormet env. Without forcing this off, "checking package dependencies" is a
# hard ERROR before any rename-relevant checks (NAMESPACE/man consistency,
# examples, tests) even run. Setting it to false downgrades that to an
# informational note (matching how a CI runner with those deps present would
# behave for everything else) so the actual check can proceed.
set -euo pipefail
module purge; unset LD_LIBRARY_PATH PYTHONPATH PYTHONHOME
module load apps/binapps/anaconda3/2024.10
export LD_LIBRARY_PATH="/usr/lib64:/lib64:${LD_LIBRARY_PATH:-}"
source activate rnormet
cd /net/scratch/n94921cs/normet-r

export _R_CHECK_FORCE_SUGGESTS_=false

# This node has RTC-in-local-timezone enabled (a system config issue, not
# fixable from a job script), which makes R print a spurious "system is
# configured to read the RTC time..." warning that R CMD check then
# misattributes to whatever check step happens to be running at the time,
# polluting nearly every WARNING/NOTE section with noise unrelated to the
# actual check. Setting TZ explicitly avoids the code path that triggers it.
export TZ=UTC

Rscript -e '
if (!requireNamespace("rcmdcheck", quietly = TRUE)) {
  install.packages("rcmdcheck", repos = "https://cloud.r-project.org")
}
res <- rcmdcheck::rcmdcheck(
  args = c("--no-manual"),
  error_on = "warning",
  check_dir = "/net/scratch/n94921cs/normet-r/normet.Rcheck"
)
saveRDS(res, "/net/scratch/n94921cs/normet-r/ci_check_result.rds")
print(res)
'
echo "=== R CMD check complete; full log at /net/scratch/n94921cs/normet-r/normet.Rcheck/00check.log ==="
