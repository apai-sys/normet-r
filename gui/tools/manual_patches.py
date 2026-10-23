"""normet-py's user manual, rewritten for this window: patches to its two books.

``PATCHES[file]`` holds ``(label, old, new)`` as ``r_patches.py`` does; ``old`` is either
text that must occur exactly once, or ``(start, end)``, a passage from ``start`` up to
(not including) ``end``, each occurring once. See ``vendor_py_gui.py``.

The window is normet-py's, screen for screen, so most of the book stands as it is. What
is patched is what differs because the window runs the R package: how it is installed;
its backends (LightGBM and H2O AutoML where normet-py has FLAML and LightGBM, and no
Chronos-2); the functions behind each step, by their R names; the command log and a
session script, which are R; scripting, which is R and ``nm_mcp_server()``; the defaults
and files; and the numbers quoted, which are this window's own run (``walk_gui.py``).
"""

PATCHES: dict[str, list[tuple[str, object, str]]] = {}

EN = "docs/manual/normet_manual.tex"
ZH = "docs/manual/normet_manual_zh.tex"


def patch(file: str, label: str, old: str, new: str) -> None:
    PATCHES.setdefault(file, []).append((label, old, new))


def fill(text: str) -> str:
    """``text`` with each ``@name@`` replaced by the number ``N[name]``."""
    import re

    return re.sub(r"@(\w+)@", lambda m: N[m.group(1)], text)


def passage(file: str, label: str, start: str, end: str, new: str) -> None:
    """The text from ``start`` up to ``end`` replaced by ``new`` (which begins with
    ``start`` again where it is kept)."""
    PATCHES.setdefault(file, []).append((label, (start, end), new))


#: The numbers the text quotes, from this window's run for the figures
#: (``walk_gui.py``: MY1, LightGBM with 10 search trials, 300 draws; the ULEZ panel).
N = {
    "test_n": "1,449",
    "train_n": "4,344",
    "test_r2": "0.991",
    "test_rmse": "2.42",
    "train_r2": "0.991",
    "norm_diff": "$-0.20$",
    "obs": "60.3 & 65.2 & 51.7 & 34.5 & 30.7 & 35.1 & 31.6 & 36.6",
    "norm": "60.0 & 64.9 & 54.7 & 33.2 & 31.1 & 32.2 & 31.9 & 35.8",
    "feb_apr_norm": "31.7~\\ugm{}",
    "feb_apr_pct": "49\\,\\%",
    "feb_apr_obs": "30.7~\\ugm{}",
    "mar_cleaner": "3.0",
    "emi_base": "43.0",
    "emi_trend": "6.59",
    "emi_season": "8.34",
    "emi_diurnal": "9.42",
    "emi_weekly": "4.18",
    "met_total": "16.60",
    "met_wind": "9.81",
    "met_thermo": "4.92",
    "met_mixing": "6.00",
    "met_sky": "4.57",
    "ms_fast": "3.0",
    "scm_att": "-18.15",
    # the uncertainty run of the figure's settings (three members, 50 shared draws,
    # lightgbm): median shares in whole percents, and the total's median variance.
    # walk_gui.py prints them; they are this window's R run, not normet-py's.
    "unc_w": "96",
    "unc_i": "4",
    "unc_m": "0",
    "unc_total": "159.4",
}


# == the English book ========================================================================

# -- what this book is ---------------------------------------------------------------------
patch(EN, "header", r"""% Figures: docs/manual/make_figures.py   (screenshots of the real window)""",
      r"""% Figures: gui/tools/walk_gui.py   (screenshots of the R window)
% This is normet-py's book, rewritten for the window of the normet R package by
% gui/tools/vendor_py_gui.py and the patches in gui/tools/manual_patches.py.""")
patch(EN, "running head", r"""\fancyhead[L]{\small\textsc{normet User Manual}}""",
      r"""\fancyhead[L]{\small\textsc{normet User Manual} (R)}""")
patch(EN, "title", r"""{\large\bfseries User Manual\par}""",
      r"""{\large\bfseries User Manual\par}
\vspace{0.2cm}
{\large the window of the normet R package\par}""")
patch(EN, "title blurb", r"""{\large A desktop application and Python library for removing the weather\\
from air-quality records and asking what an intervention changed.\par}""",
      r"""{\large An R package, and a desktop window on it, for removing the weather\\
from air-quality records and asking what an intervention changed.\par}""")
patch(EN, "what is normet", r"""\nm{} is a desktop application and Python library for the analysis of environmental
time series,""", r"""\nm{} is an R package, with a desktop window, for the analysis of environmental
time series,""")
patch(EN, "calls into R", r"""Everything the window does is a call into the \nm{} Python package, which can be
scripted, run from the command line, or driven by an AI assistant over the Model
Context Protocol (Chapter~\ref{ch:script}). The window writes down each call it makes,
so an analysis done by clicking can be saved as a script that repeats it
(Section~\ref{sec:commandlog}).""", r"""Everything the window does is a call into the \nm{} R package, run by \code{Rscript}
in an R process of its own; the same functions are scripted in R, or driven by an AI
assistant over the Model Context Protocol (Chapter~\ref{ch:script}). The window writes
down each call it makes, so an analysis done by clicking can be saved as an R script that
repeats it (Section~\ref{sec:commandlog}). The window is normet-py's, the same screen for
screen; what it runs is R.""")
patch(EN, "features: training", r"""  \item AutoML training with FLAML (an estimator search within a time budget) or a
        tuned LightGBM, with the held-out fit reported as $R^2$, RMSE and nine
        further statistics.""", r"""  \item Training with LightGBM (a random hyperparameter search) or H2O AutoML (an
        algorithm search within a time budget), with the held-out fit reported as
        $R^2$, RMSE and nine further statistics.""")
patch(EN, "features: no Chronos-2", r"""  \item Zero-shot de-weathering with the Chronos-2 time-series foundation model, on
        the same result schema --- no training needed.
""", "")
patch(EN, "figures made by", r"""The figures are screenshots of the real window, made by
\code{docs/manual/make\_figures.py} on the record""", r"""The figures are screenshots of the real window, made by
\code{gui/tools/walk\_gui.py} on the record""")
patch(EN, "a run of your own", r"""A run of your own will differ in the last digit or two: the AutoML
search is bounded by wall-clock time, so it does not visit exactly the same candidates
twice.""", r"""A run of your own should match them closely: LightGBM's search and every
draw are seeded, though LightGBM's threads may move a last digit.""")

# -- installation: R and the package, then the window --------------------------------------
passage(EN, "installation", r"""% ============================ 2. INSTALLATION ===============================""",
        r"""% ============================ 3. METHODOLOGY =================================""", r"""% ============================ 2. INSTALLATION ===============================
\chapter{Installation}\label{ch:install}

The window runs the \nm{} R package, so R and the package come first; then the window,
as an application or from the repository.

\section{R and the normet package}
\nm{} needs R~4.1 or newer. In R:
\begin{lstlisting}[language=R]
install.packages(c("remotes", "lightgbm"))
remotes::install_github("apai-sys/normet-r")
install.packages("h2o")      # optional: the H2O AutoML backend (needs Java)
\end{lstlisting}
LightGBM is the default backend. H2O AutoML is optional and needs a Java runtime; the
window starts its cluster when an H2O step runs and shuts it down when the window closes.
The window finds \code{Rscript} on the \code{PATH} or where R installs it;
\tab{R $\rightarrow$ Locate Rscript\ldots} points it at another, and
\tab{R $\rightarrow$ Check R environment} asks again which R, which \nm{} and which
backends there are. The status bar shows R's version, its tooltip \nm{}'s and the
backends that load; a notice says what to install when something is missing.

\section{macOS}
Open \code{Normet-1.0.0-macos-arm64.dmg} and drag \code{Normet.app} onto the
\code{Applications} folder. The application carries its own Python and Qt, not R: it runs
the R installed on the machine. The first launch takes longer than the rest while it
builds a font cache, which later launches reuse (it is kept in
\code{\textasciitilde/.normet/matplotlib}); a splash screen shows meanwhile.

\note{The application is not signed with an Apple Developer ID. The first time, open it
by right-clicking \code{Normet.app} and choosing \emph{Open}, then confirming in the
dialog; this is needed only once. Alternatively run
\code{xattr -dr com.apple.quarantine /Applications/Normet.app} in Terminal.}

\section{Windows and Linux}
On Windows run \code{normet-setup-1.0.0.exe}, an Inno~Setup wizard that adds Start-menu
and optional desktop shortcuts. The installer is unsigned, so SmartScreen shows
\emph{Windows protected your PC} on first run: choose \emph{More info} $\rightarrow$
\emph{Run anyway}. On Linux download \code{Normet-1.0.0-x86\_64.AppImage}, mark it
executable (\code{chmod +x}) and run it. On a minimal distribution Qt may need
\code{libegl1 libgl1 libxkbcommon0 libdbus-1-3 libxcb-cursor0}.

The installers are built by the repository's \code{build-gui.yml} workflow (one per
operating system; PyInstaller cannot cross-compile) and are attached to its runs under
\emph{Actions $\rightarrow$ Artifacts}. \code{gui/packaging/README.md} explains how to
build one locally.

\section{From the repository}
The window is a Python package in the repository's \code{gui} folder. It needs
Python~3.10 or newer:
\begin{lstlisting}[language=bash]
python -m venv .venv && source .venv/bin/activate
pip install "git+https://github.com/apai-sys/normet-r#subdirectory=gui"
normet-r-gui                         # or: normet-r-gui mydata.csv
\end{lstlisting}
Its extra \code{geo} adds Shapely and pyshp, for source regions read from GeoJSON or
Shapefile files in the Transport Studio.

""")

# -- methodology: R's functions -------------------------------------------------------------
patch(EN, "prepare", r"""Before a model is trained the table goes through \code{prepare\_data}, in this order:""",
      r"""Before a model is trained the table goes through \code{nm\_prepare\_data}, in this order:""")
passage(EN, "training", r"""\section{Training the model}\label{sec:train}""", r"""\subsection{Model statistics}\label{sec:modstats}""",
        r"""\section{Training the model}\label{sec:train}
\nm{} trains gradient-boosted trees (by default) that map the predictors to the target.
Two backends are offered:
\begin{description}\nosep
  \item[LightGBM] (the default) LightGBM with a random hyperparameter search of a set
        number of \emph{trials}, each scored by cross-validation (50 trials in the
        library, 20 in the window).
  \item[H2O AutoML] An AutoML search over the algorithms ticked (GBM alone by default;
        DRF, GLM, deep learning, XGBoost and stacked ensembles can be added) within a
        wall-clock \emph{time budget} (\code{max\_runtime\_secs}, 60~s), on a local H2O
        cluster.
\end{description}
LightGBM's search is seeded, so the same script on the same data finds the same model.
Because H2O's budget is wall-clock time, the same script can stop at a different
candidate on a busier machine; set \code{max\_models} in \code{model\_config} for a search
bounded by models instead.

""")
patch(EN, "modstats", r"""\code{modStats} predicts the training rows,""", r"""\code{nm\_modStats} predicts the training rows,""")
patch(EN, "normalise_auto", r"""noisier. \code{normalise\_auto} chooses $N$ for you:""", r"""noisier. \code{nm\_normalise\_auto} chooses $N$ for you:""")
patch(EN, "conditional pool", r"""meteorology. \code{conditional\_on} restricts the pool to rows meeting a condition --- a value, a list
of values, or a function of the column, as \code{\{"ws": lambda v: v < 2\}} draws from
calm hours only. \code{resample\_pools} draws some variables from a pool of
their own: \code{\{"transport": clean\_hours[traj\_cols]\}} draws""", r"""meteorology. \code{conditional\_on} (of \code{nm\_normalise\_ext}) restricts the pool to rows
meeting a condition --- a value, a vector of values, or a function of the column, as
\code{list(ws = function(v) v < 2)} draws from calm hours only. \code{resample\_pools}
draws some variables from a pool of their own: \code{list(transport = clean\_hours[traj\_cols])}
draws""")
patch(EN, "seed", r"""\paragraph{Reproducibility.} The draws are seeded (\code{seed=7654321} by default), so the""",
      r"""\paragraph{Reproducibility.} The draws are seeded (\code{seed = 7654321} by default), so the""")
patch(EN, "groups", r"""\paragraph{Groups.} \code{groups=\{"local": met\_cols, "transport": traj\_cols\}} gives one""",
      r"""\paragraph{Groups.} \code{groups = list(local = met\_cols, transport = traj\_cols)} gives one""")
patch(EN, "rolling", r"""\code{rolling} normalises the record window by window:""", r"""\code{nm\_rolling} normalises the record window by window:""")
passage(EN, "no Chronos-2", r"""\section{Zero-shot de-weathering with Chronos-2}\label{sec:chronos}""",
        r"""\section{Synthetic control}\label{sec:scmtheory}""", "")
patch(EN, "mlscm", r"""  \item[\code{mlscm}] ML-augmented SCM (\emph{experimental}): an AutoML model maps donor""",
      r"""  \item[\code{mlscm}] ML-augmented SCM (\emph{experimental}): a LightGBM or H2O model maps donor""")
patch(EN, "bayesian", r"""  \item[\code{bayesian}] Bayesian simplex SCM (PyMC): a Dirichlet prior on the weights,
        giving posterior credible bands directly.""", r"""  \item[\code{bayesian}] Bayesian simplex SCM: a flat Dirichlet prior on the weights,
        sampled by Markov chain Monte Carlo, giving posterior credible bands directly.""")
patch(EN, "diagnostics", r"""\code{scm\_diagnostics} reports the pre-cutoff fit""", r"""\code{nm\_scm\_diagnostics} reports the pre-cutoff fit""")
patch(EN, "noise fits", r"""fitted with $R^2 = -0.05$ from 5 donors, 0.69 from 20 and 0.997 from 53; classic SCM, with
40 random-walk donors over 12 months, fits a shuffled series with 0.60. So the SCM Studio""",
      r"""fitted with $R^2 = 0.06$ from 5 donors, 0.81 from 20 and 0.999 from 53. So the SCM Studio""")
patch(EN, "conformal", r"""  \item[Conformal interval] \code{conformal\_effect\_interval} gives a finite-sample
        interval for the average post-period effect (Chernozhukov, W\"uthrich and Zhu,
        2021); \code{rmspe\_ratio\_test} gives Abadie's post/pre RMSPE-ratio test.""",
      r"""  \item[Conformal interval] \code{nm\_conformal\_effect\_interval} gives a finite-sample
        interval for the average post-period effect (Chernozhukov, W\"uthrich and Zhu,
        2021); \code{nm\_rmspe\_ratio\_test} gives Abadie's post/pre RMSPE-ratio test.""")

# -- getting started: the package's data sets -------------------------------------------------
patch(EN, "my1", r"""2020, the UK's COVID-19 lockdown in it (\code{load\_my1()} below).""",
      r"""2020, the UK's COVID-19 lockdown in it (\code{my1} below).""")
patch(EN, "my1_pm25", r"""        \PMtwo{} at the same site, its own wind and temperature with ERA5's other fields
        (\code{load\_my1\_pm25()}).""", r"""        \PMtwo{} at the same site, its own wind and temperature with ERA5's other fields
        (\code{my1\_pm25}).""")
passage(EN, "data sets", r"""The real records of the \nm{} model-description paper ship with the package; in a script""",
        r"""Sources: UK AURN (Defra, Open Government Licence v3.0)""", r"""The real records of the \nm{} model-description paper ship with the package, as its data
sets (in a script, \code{my1} once \code{library(normet)} is loaded):
\begin{center}\small
\begin{tabular}{@{}lp{7.0cm}p{3.2cm}@{}}
\toprule
Data set & Contents & Used for \\
\midrule
\code{my1}      & Hourly \NOtwo{} + ERA5 met, London Marylebone Road, Jan--Aug 2020 & de-weathering \\
\code{scm}      & Monthly de-weathered \NOtwo{}, 104 UK sites, 2016--2021 & synthetic control (ULEZ) \\
\code{my1\_pm25} & Hourly \PMtwo{} + met at MY1, Jan--Aug 2020 & transport-aware case \\
\code{traj\_my1} & 6-hourly HYSPLIT trajectory features arriving at MY1 & transport-aware case \\
\code{extdata/traj} & Two days of raw HYSPLIT \code{tdump} files (\code{system.file("extdata", "traj", package = "normet")}) & Transport Studio \\
\bottomrule
\end{tabular}
\end{center}
""")

# -- the interface: R's functions, R's backends, Cancel ends R --------------------------------
patch(EN, "model page", r"""  \item[Model] Backend, split, training fraction, time budget (or search trials),
        estimators, seed; for Chronos-2 the device and fine-tuning instead
        (Chapter~\ref{ch:train}).""", r"""  \item[Model] Backend, split, training fraction, search trials (or, for H2O, the time
        budget and the algorithms), seed (Chapter~\ref{ch:train}).""")
patch(EN, "run buttons", r"""Train model / Load Chronos-2 & a table, one predictor ticked & \code{build\_model} \\
Fine-tune Chronos-2   & Chronos-2 loaded         & \code{finetune} \\
Run normalisation     & a model, one variable to resample & \code{normalise} \\
Run decomposition     & a model                  & \code{decompose} \\
Run rolling normalisation & an AutoML model      & \code{rolling} \\
Multi-scale decomposition & an AutoML model, a normalisation & \code{rolling} $\times 3$ \\
Trend test          & an AutoML model (a decomposition, where it tests one) & \code{trend} (1 segment), \code{detect\_trend\_breaks} (more) \\
Compute PDP           & an AutoML model, one variable ticked & \code{pdp} \\""",
      r"""Train model           & a table, one predictor ticked & \code{nm\_build\_model} \\
Run normalisation     & a model, one variable to resample & \code{nm\_normalise} \\
Run decomposition     & a model                  & \code{nm\_decompose} \\
Run rolling normalisation & a model              & \code{nm\_rolling} \\
Multi-scale decomposition & a model, a normalisation & \code{nm\_rolling} $\times 3$ \\
Trend test          & a model (a decomposition, where it tests one) & \code{nm\_trend} (1 segment), \code{nm\_trend\_breaks} (more) \\
Compute PDP           & a model, one variable ticked & \code{nm\_pdp} \\""")
patch(EN, "trend reference",
      r"""        whether the series the decomposition just drew is rising, falling or flat, and
        the \tab{Uncertainty} tab where the band's spread comes from (Section~\ref{sec:uncertainty}).""",
      r"""        whether the series the decomposition just drew is rising, falling or flat
        (Section~\ref{sec:trend}), and the \tab{Uncertainty} tab where the band's
        spread comes from (Section~\ref{sec:uncertainty}).""")
patch(EN, "trend breaks name",
      r"""\emph{segmented fit} instead --- \code{detect\_trend\_breaks} on the chosen""",
      r"""\emph{segmented fit} instead --- \code{nm\_trend\_breaks} on the chosen""")
patch(EN, "trend script names",
      r"""(\code{trend\_breaks\_call} in the script, not \code{trend\_call})""",
      r"""(\code{nm\_trend\_breaks} in the script, not \code{nm\_trend})""")
patch(EN, "trend breaks caption",
      r"""\screenshot{ui_trend_breaks.png}{The segmented fit (Segments 2) on MY1's separated
long-term trend: the search found the break at 2020-03-18 19:00 --- the 2020-03-23
lockdown's lead-in --- the single-slope SSE down 88.7\,\% with the block-bootstrap
p of the search 0.001, the one to quote. Segment 1 runs +0.0812 per day
(95\,\% [0.0761, 0.0863]); segment 2 flattens to $-$0.0121 per day
(95\,\% [$-$0.0134, $-$0.0108]). The piecewise Theil--Sen lines and the marked
break are in the figure; the per-segment table and the verdict above it are the
Trend tab's.}{fig:trend_breaks}""",
      r"""\screenshot{ui_trend_breaks.png}{The segmented fit (Segments 2) on MY1's separated
long-term trend: the search found the break at 2020-03-25 20:00 --- two days after
the 2020-03-23 lockdown began --- the single-slope SSE down 79.6\,\% with the
block-bootstrap p of the search 0.001, the one to quote. Segment 1 runs +0.03562 per
day (95\,\% [0.03173, 0.03937]); segment 2 eases to +0.00512 per day
(95\,\% [0.00362, 0.00660]). The piecewise Theil--Sen lines and the marked
break are in the figure; the per-segment table and the verdict above it are the
Trend tab's.}{fig:trend_breaks}""")
patch(EN, "task clock", r"""Where the task says how far it has come
--- the rolling windows, the decomposition's steps, LightGBM's trials, the receptor times
HYSPLIT runs, FLAML's time budget --- the progress bar fills with it,""", r"""Where the task says how far it has come
--- R reports the Monte-Carlo batches, the rolling windows, the decomposition's steps,
LightGBM's trials and the receptor times HYSPLIT runs; for H2O it is the time against its
budget --- the progress bar fills with it,""")
patch(EN, "cancel", r"""Cancel \emph{abandons} the task: the window is
free at once, but the computation cannot be interrupted, so it finishes in the background
and its result is discarded.""", r"""Cancel stops the task: the R process doing it is
ended, with whatever it started (a HYSPLIT run, say), and the window is free at once.""")
patch(EN, "R menu", r"""Help     & User Manual                          & F1 \\""",
      r"""R        & Locate Rscript\ldots, Check R environment, Save Figure as R Script\ldots & \\
Help     & User Manual                          & F1 \\""")
patch(EN, "log dock", r"""stay open beside the main window: what each step did, how many rows, FLAML's chosen
estimator and its hyperparameters, how many windows a rolling run made.""",
      r"""stay open beside the main window: each call into R (\code{R> nm\_normalise(\ldots)}) and
R's own lines --- what each step did, how many rows, LightGBM's search trials, how many
windows a rolling run made.""")
patch(EN, "failed task", r"""When a task fails, its full traceback is written to the
Log and its last line shown in a dialog.""", r"""When a task fails, R's error is written to the
Log, with the traceback, and shown in a dialog.""")

# -- training --------------------------------------------------------------------------------
passage(EN, "settings", r"""\section{Settings}
\begin{description}\nosep
  \item[Backend] \code{flaml}""", r"""\section{Reading the Model tab}""", r"""\section{Settings}
\begin{description}\nosep
  \item[Backend] \code{lightgbm} (the default) or \code{h2o}. H2O needs Java and the
        \code{h2o} R package; \tab{R $\rightarrow$ Check R environment} says whether it
        loads.
  \item[Split method, Training fraction] Section~\ref{sec:split}; 0.75 by default.
  \item[Search trials] LightGBM's random-search trials, 20 by default. For H2O the row
        becomes \emph{Time budget}, 60~s by default; each backend's value is kept when you
        switch.
  \item[Algorithms] (H2O only) GBM alone by default; add more to widen the search.
  \item[Seed] 7654321 by default: the split and the search are seeded with it.
\end{description}

""")
patch(EN, "train runs", r"""\emph{Train model} runs \code{build\_model} --- preparation, the split and the search ---""",
      r"""\emph{Train model} runs \code{nm\_build\_model} --- preparation, the split and the search ---""")
patch(EN, "model table", r"""is \code{modStats} for the training rows, the testing rows and all rows""",
      r"""is \code{nm\_modStats} for the training rows, the testing rows and all rows""")
patch(EN, "importance", r"""importance (split counts for LightGBM).""", r"""importance (each predictor's share of LightGBM's gain).""")
patch(EN, "model caption", r"""\screenshot{ui_model.png}{MY1 trained with FLAML (LightGBM, 30~s budget, random split):
on the 1,448 held-out hours $R^2 = 0.883$ and RMSE $= 8.66$~\ugm{}, against $0.976$ on
the 4,345 training hours. Wind direction and speed, the boundary-layer height and the
trend carry the most splits.}{fig:model}""", fill(r"""\screenshot{ui_model.png}{MY1 trained with LightGBM (10 search trials, random split):
on the @test_n@ held-out hours $R^2 = @test_r2@$ and RMSE $= @test_rmse@$~\ugm{}, against
$@train_r2@$ on the @train_n@ training hours. The calendar --- the day of the year, the trend
and the hour --- and the wind direction carry the most gain.}{fig:model}"""))
patch(EN, "a poor fit", r"""moderate or poor model, try more predictors, a longer budget or more estimators.""",
      r"""moderate or poor model, try more predictors, more search trials, or H2O.""")
passage(EN, "no Chronos-2 settings", r"""\section{Chronos-2}\label{sec:chronosui}""",
        r"""% ============================ 7. NORMALISATION ================================""", "")

# -- normalising, decomposing, rolling ---------------------------------------------------------
patch(EN, "samples", r"""  \item[Samples] Monte-Carlo draws, 300 by default (8 on Chronos-2;
        Section~\ref{sec:normalise} on how many are enough).""", r"""  \item[Samples] Monte-Carlo draws, 300 by default (Section~\ref{sec:normalise} on how
        many are enough).""")
patch(EN, "cycle profiles", r"""above is shown at. In a script: \code{nm.cycle\_profiles(result, ["observed",
"normalised"])}.""", r"""above is shown at. In R: \code{nm\_cycle\_profiles(result, c("observed",
"normalised"))}.""")
patch(EN, "normalise numbers", r"""and the mean of normalised $-$ observed over the record: here $-0.26$~\ugm{}, since over""",
      fill(r"""and the mean of normalised $-$ observed over the record: here @norm_diff@~\ugm{}, since over"""))
patch(EN, "monthly means", r"""observed   & 60.3 & 65.2 & 51.7 & 34.5 & 30.7 & 35.1 & 31.6 & 36.6 \\
normalised & 59.7 & 64.7 & 54.0 & 34.7 & 32.1 & 32.5 & 32.1 & 33.8 \\""",
      fill(r"""observed   & @obs@ \\
normalised & @norm@ \\"""))
patch(EN, "spring drop", r"""From February to April the normalised series falls by 30.0~\ugm{} (46\,\%), against
30.7~\ugm{} observed: almost none of the spring drop was the weather. In March the weather
was cleaner than usual (observed 2.3 below normalised), in June and August dirtier.""",
      fill(r"""From February to April the normalised series falls by @feb_apr_norm@ (@feb_apr_pct@), against
@feb_apr_obs@ observed: almost none of the spring drop was the weather. In March the weather
was cleaner than usual (observed @mar_cleaner@ below normalised), in June and August dirtier."""))
patch(EN, "no Chronos-2 rows", r"""\note{On Chronos-2 the first \code{context\_length} rows are seeded with the observed
values; they are shaded grey on the figure, the line under it says how many there are,
and the mean is taken over the rest.}

""", "")
patch(EN, "emission caption", r"""normalisation; baseline 43.1~\ugm{}). The lockdown appears as a step in both the trend
($\sigma = 9.56$) and the seasonal component ($\sigma = 4.74$): a one-off event is not a
season, and the record is too short to tell them apart. The diurnal cycle (right) is the
largest ($\sigma = 9.92$):""", fill(r"""normalisation; baseline @emi_base@~\ugm{}). The lockdown appears as a step in both the trend
($\sigma = @emi_trend@$) and the seasonal component ($\sigma = @emi_season@$): a one-off event is not a
season, and the record is too short to tell them apart. The diurnal cycle (right) is the
largest ($\sigma = @emi_diurnal@$):"""))
patch(EN, "weekly", r"""($\sigma = 3.36$) dips at the weekend.}{fig:emission}""",
      fill(r"""($\sigma = @emi_weekly@$) dips at the weekend.}{fig:emission}"""))
patch(EN, "met caption", r"""$\sigma = 16.79$~\ugm{}) split among four groups by exact Shapley values (16 coalitions):
wind (\code{ws}, \code{wd}; $\sigma = 9.92$), thermodynamics (\code{temp}, \code{RH};
5.24), mixing (\code{blh}, \code{atmos\_pres}; 4.89) and sky (\code{tcc}, \code{tp},
\code{ssrd}; 3.44).}{fig:metdecomp}""", fill(r"""$\sigma = @met_total@$~\ugm{}) split among four groups by exact Shapley values (16 coalitions):
wind (\code{ws}, \code{wd}; $\sigma = @met_wind@$), thermodynamics (\code{temp}, \code{RH};
@met_thermo@), mixing (\code{blh}, \code{atmos\_pres}; @met_mixing@) and sky (\code{tcc}, \code{tp},
\code{ssrd}; @met_sky@).}{fig:metdecomp}"""))
patch(EN, "multiscale caption", r"""synoptic band carries the most ($D_\text{fast}$, $\sigma \approx 3.0$), then the intra-seasonal""",
      fill(r"""synoptic band carries the most ($D_\text{fast}$, $\sigma \approx @ms_fast@$), then the intra-seasonal"""))

# -- the SCM Studio --------------------------------------------------------------------------
patch(EN, "ULEZ in R", r"""\begin{lstlisting}[language=Python]
import normet as nm
scm_df = nm.datasets.load_scm()
df = scm_df.query("'2017-01-01' <= date < '2020-03-01'")
df = df[df["type"].str.contains("Traffic")]
counts = df.dropna(subset=["NO2_dw"]).groupby("code").size()
donors = [c for c in counts[counts == df["date"].nunique()].index if c != "MY1"]
df = df[df["code"].isin(donors + ["MY1"])]
df.to_csv("ulez_panel.csv", index=False)
\end{lstlisting}""", r"""\begin{lstlisting}[language=R]
library(normet)
df <- subset(scm, date >= as.Date("2017-01-01") & date < as.Date("2020-03-01"))
df <- df[grepl("Traffic", df$type), ]
counts <- table(df$code[!is.na(df$NO2_dw)])
donors <- setdiff(names(counts)[counts == length(unique(df$date))], "MY1")
df <- df[df$code %in% c(donors, "MY1"), ]
write.csv(df, "ulez_panel.csv", row.names = FALSE)
\end{lstlisting}""")
patch(EN, "similarity", r"""  \item[Rank donors by similarity] (needs the \code{foundation} extra) Embeds every
        unit's pre-cutoff record with Chronos-2 and ranks the others by the cosine
        similarity of their dynamics to the treated unit's, on the \tab{Similarity} tab;
        \emph{Tick the top N} and \emph{Apply} make those the pool.
""", "")
patch(EN, "ML backend", r"""\emph{Backend} chooses the estimator (Section~\ref{sec:scmtheory}); \emph{ML backend} and
\emph{Time budget} (15~s) apply to \code{mlscm}, \emph{Draws} (1000) to
\code{bayesian}.""", r"""\emph{Backend} chooses the estimator (Section~\ref{sec:scmtheory}); \emph{ML backend}
(\code{lightgbm} or \code{h2o}) and \emph{Search trials} (5; for H2O \emph{Time budget},
15~s) apply to \code{mlscm}, \emph{Draws} (1000) to \code{bayesian}.""")
patch(EN, "fit caption", r"""\screenshot{ui_scm_fit.png}{The augmented SCM (\code{scm}) fit for MY1: ATT $=
-18.14$~\ugm{}""", fill(r"""\screenshot{ui_scm_fit.png}{The augmented SCM (\code{scm}) fit for MY1: ATT $=
@scm_att@$~\ugm{}"""))
patch(EN, "top donor", r"""anything. Its top donor carries 99.5\,\% of the weight ($\text{HHI} = 0.99$), but those""",
      r"""anything. Its top donor carries all of the weight ($\text{HHI} = 1.00$), but those""")
patch(EN, "scm row", r"""\code{scm}    & 0.999  & 1.000   & 0.16  & $-18.14$ \\""",
      fill(r"""\code{scm}    & 0.999  & 1.000   & 0.16  & $@scm_att@$ \\"""))
patch(EN, "bands caption", r"""out one donor each time. The mean post-cutoff effect is $-18.14$~\ugm{}, and the band""",
      fill(r"""out one donor each time. The mean post-cutoff effect is $@scm_att@$~\ugm{}, and the band"""))

# -- getting data in ---------------------------------------------------------------------------
patch(EN, "multisite", r"""\code{do\_all\_multisite}. A table without times""", r"""\code{nm\_do\_all\_multisite}. A table without times""")
patch(EN, "read_time_series", r"""open file again. In a script, \code{nm.io.read\_time\_series(path, zone=\ldots)} reads a
table the same way.""", r"""open file again. In R, \code{nm\_read\_time\_series(path, zone = \ldots)} reads a
table the same way.""")
patch(EN, "CDS", r"""\item \textbf{Meteorology.} Open-Meteo's ERA5 archive (no key), or the Copernicus CDS
        (needs \code{\textasciitilde/.cdsapirc}).""", r"""\item \textbf{Meteorology.} Open-Meteo's ERA5 archive (no key), or the Copernicus CDS
        (needs the \code{ecmwfr} R package and a CDS key, set with
        \code{ecmwfr::wf\_set\_key}).""")
patch(EN, "openair", r"""The archives are the openair \code{.RData} files R's \code{importUKAQ()} reads, parsed
without R, so the data match an openair workflow. The Data Studio needs an internet
connection; a table sent from it is held in memory, and the command log says so rather
than writing a \code{read\_csv} it could not repeat.""", r"""The archives are the openair \code{.RData} files R's \code{importUKAQ()} reads, read by
the R package (\code{nm\_fetch\_ukaq\_measurements}), so the data match an openair
workflow. The Data Studio needs an internet connection; a table sent from it is held in
memory, and the command log says so rather than writing a \code{nm\_read\_time\_series} it
could not repeat.""")
patch(EN, "polar", r"""\code{nm.polar\_plot(df, target="NO2", ws\_col="ws", wd\_col="wd")}.""",
      r"""\code{nm\_plot\_polar(df, target = "NO2", ws\_col = "ws", wd\_col = "wd")} in R.""")

# -- exporting and reproducing: R ----------------------------------------------------------------
patch(EN, "report provenance", r"""result, and its provenance: \nm{}'s version, the time, the platform and Python
        version,""", r"""result, and its provenance: \nm{}'s version, the time, the platform and R
        version,""")
patch(EN, "script is R", r"""$\rightarrow$ Save Session as Script\ldots}) writes it as a Python file that repeats the
session, and \emph{Clear} empties it.""", r"""$\rightarrow$ Save Session as Script\ldots}) writes it as an R script that repeats the
session, and \emph{Clear} empties it.

The window draws its figures with matplotlib; the R package draws the same results with
ggplot2. So each result's entry ends with the R package's figure of it ---
\code{fig\_normalise <- nm\_plot\_normalise(normalised)}, and
\code{nm\_plot\_decomposition\_stack}, \code{nm\_plot\_rolling} and
\code{nm\_plot\_pdp\_grid} for the others --- drawn where the script is run in R or
RStudio (not under \code{Rscript}), and changed as any ggplot is. \tab{R $\rightarrow$ Save Figure as R
Script\ldots} writes the result the open tab shows (Normalised, Decomposition --- the
method shown --- Rolling or PDP) as a CSV, and beside it the R that reads it, draws it so
and saves it as a PDF: a figure to change in R without training the model again.""")
patch(EN, "saved session", r"""before the results were saved. A Chronos-2 checkpoint is not written (it is the
pretrained model, about 500~MB): load it again to go on. A session file is a Python pickle:
open only one you or the window wrote.""", r"""before the results were saved. A session file is a Python pickle, with the R models'
folders inside it, so it opens on another machine: open only one you or the window wrote.""")
patch(EN, "session script", r"""table, model and results, and the panel set from the calls it made. The script is Python
and runs as it is written, so the window asks first.""", r"""table, model and results, and the panel set from the calls it made --- read by R's own
parser, before it runs. The script is R and runs as it is written, in R, from the folder
it was saved in (so a table it reads by a relative path is found); the window asks
first.""")
patch(EN, "methods caption", r"""the FLAML model and its held-out fit, and each step that was run, with its
references.}{fig:methods}""", r"""the LightGBM model and its held-out fit, and each step that was run, with its
references.}{fig:methods}""")

# -- scripting: R, Rscript and the MCP server ------------------------------------------------------
passage(EN, "scripting", r"""% ============================ 15. SCRIPTING ===================================""",
        r"""% ============================ APPENDICES ======================================""", r"""% ============================ 15. SCRIPTING ===================================
\chapter{Scripting: R and MCP}\label{ch:script}

\section{The R package}
Everything the window does is a function of the \nm{} R package. The one-call pipeline
prepares, trains and normalises:
\begin{lstlisting}[language=R]
library(normet)

met <- c("ws", "wd", "temp", "RH", "atmos_pres", "blh", "tcc", "tp", "ssrd")
predictors <- c(met, "date_unix", "day_julian", "weekday", "hour")

res <- nm_do_all(my1, target = "NO2", backend = "lightgbm",
                 covariates = predictors, resample_vars = met,
                 n_samples = 300, n_cores = 4)
nm_modStats(res$df_prep, res$model)   # training, testing and all rows
\end{lstlisting}
Step by step:
\begin{lstlisting}[language=R]
built <- nm_build_model(my1, target = "NO2", backend = "lightgbm",
                        covariates = predictors, model_config = list(n_trials = 20))
df_prep <- built$df_prep
model <- built$model
norm <- nm_normalise(df_prep, model, resample_vars = met, n_samples = 300,
                     return_quantiles = c(0.025, 0.975))
auto <- nm_normalise_auto(df_prep, model, resample_vars = met)   # stops when converged
emi <- nm_decompose("emission", df = df_prep, model = model, covariates = predictors)
mets <- nm_decompose("meteorology", df = df_prep, model = model,
                     covariates = predictors,
                     groups = list(wind = c("ws", "wd"), rest = met[-(1:2)]))
roll <- nm_rolling(df_prep, model, covariates = predictors, resample_vars = met)
curves <- nm_pdp(df_prep, model, var_list = c("ws", "temp"))
\end{lstlisting}
Further functions, all exported:
\begin{center}\small
\begin{tabular}{@{}p{7.4cm}p{8.0cm}@{}}
\toprule
Function & Does \\
\midrule
\code{nm\_do\_all\_unc}       & the pipeline over \code{n\_models} seeds, with confidence bands \\
\code{nm\_do\_all\_multisite} & per-site pipelines \\
\code{nm\_cv\_score}          & walk-forward cross-validation \\
\code{nm\_run\_scm}, \code{nm\_scm\_all} & a synthetic control; every unit as if treated \\
\code{nm\_placebo\_in\_space}, \code{nm\_placebo\_in\_time} & placebo tests \\
\code{nm\_uncertainty\_bands}, \code{nm\_effect\_bands\_space} & jackknife/bootstrap and placebo bands \\
\code{nm\_scm\_diagnostics}, \code{nm\_conformal\_effect\_interval} & fit diagnostics; conformal interval \\
\code{nm\_bayesian\_scm}      & Bayesian SCM \\
\code{nm\_detect\_events}, \code{nm\_anomaly\_scores} & events in a normalised series \\
\code{nm\_plot\_normalise}, \code{nm\_plot\_decomposition\_stack}, \code{nm\_plot\_scm\_dashboard} & figures (ggplot2) \\
\code{nm\_make\_run}, \code{nm\_save\_run}, \code{nm\_generate\_html} & provenance and reports \\
\code{nm\_trend}               & the trend test with the block-bootstrap correction (the \tab{Trend} tab, Section~\ref{sec:trend}) \\
\code{nm\_trend\_breaks}       & segmented trend: where the level or slope breaks (BIC + block-bootstrap gate) \\
\code{nm\_decompose\_uncertainty} & the total spread attributed to weather, model form and their interaction (the \tab{Uncertainty} tab, Section~\ref{sec:uncertainty}) \\
\code{nm\_make\_cache}        & on-disk caching \\
\bottomrule
\end{tabular}
\end{center}
Each function's help page (\code{?nm\_normalise}) gives its arguments and an example, and
the reference at \url{https://github.com/apai-sys/normet-r} lists them by area.

\section{Rscript}\label{sec:cli}
The package has no command of its own: an R script runs with \code{Rscript}, and the
script the command log saves is one (Section~\ref{sec:commandlog}):
\begin{lstlisting}[language=bash]
Rscript normet_session.R        # repeats the window's session
\end{lstlisting}
\code{nm\_make\_run} and \code{nm\_save\_run} keep a result with its provenance (an
\code{.rds} with a \code{.meta.json} beside it), which \code{nm\_generate\_html} turns into
an HTML report.

\section{AI assistants over MCP}\label{sec:mcp}
\code{nm\_mcp\_server()} serves \nm{} to an AI assistant over the Model Context Protocol, on
stdio:
\begin{lstlisting}[language=bash]
claude mcp add normet -- Rscript -e "normet::nm_mcp_server()"     # Claude Code
# Claude Desktop, claude_desktop_config.json:
#   {"mcpServers": {"normet": {"command": "Rscript",
#                              "args": ["-e", "normet::nm_mcp_server()"]}}}
\end{lstlisting}
Its tools are normet-py's \code{normet-mcp}'s, by the same names: the assistant can list
the examples, inspect a table, start do-all, decompose, SCM and cross-validation jobs,
follow and cancel them, read a run or a result, draw a figure and write a report. Each job
is an R script, \code{job.R}, run by \code{Rscript} in a folder of its own
(\code{\$NORMET\_MCP\_HOME}, \code{\textasciitilde/.normet/mcp-r} by default), so the script
is its record and runs again without the assistant. The assistant is given \nm{}'s
readings of a table or result, not the data; files are read only under
\code{\$NORMET\_MCP\_ROOTS} (your home folder by default). The server asks the assistant to
propose the target, predictors and donor pool with its reasons, to let you confirm them,
and to quote only the numbers the tools return. In R, \code{nm\_agent\_tool()} calls the
same tools.

""")

# -- appendices ------------------------------------------------------------------------------------
patch(EN, "defaults: training", r"""FLAML time budget              & 60 s & 90 s \\
FLAML estimators               & lgbm & lgbm \\
FLAML metric                   & $R^2$ & $R^2$ \\
LightGBM search trials         & 20 & --- \\""", r"""LightGBM search trials         & 20 & 50, each scored by 5-fold CV \\
H2O time budget                & 60 s & 60 s \\
H2O algorithms                 & GBM & GBM \\""")
patch(EN, "defaults: samples", r"""Normalisation samples          & 300 (Chronos-2: 8) & 300 (Chronos-2: 8) \\""",
      r"""Normalisation samples          & 300 & 300 \\""")
patch(EN, "defaults: auto", r"""\code{normalise\_auto}          & --- &""", r"""\code{nm\_normalise\_auto}       & --- &""")
patch(EN, "defaults: no Chronos-2", r"""Chronos-2 context / horizon    & 2048 / 168 rows & 2048 / 168 rows \\
""", "")
patch(EN, "files: settings", r"""Window geometry, appearance, language, Assistant model & the system's settings store (\code{apai-sys/normet-gui}) \\""",
      r"""Window geometry, appearance, language, Assistant model, Rscript & the system's settings store (\code{apai-sys/normet-r-gui}) \\""")
patch(EN, "files: jobs", r"""MCP jobs                     & \code{\$NORMET\_MCP\_HOME}, default \code{\textasciitilde/.normet/mcp} \\
Chronos-2 weights            & the Hugging Face cache \\""", r"""MCP jobs                     & \code{\$NORMET\_MCP\_HOME}, default \code{\textasciitilde/.normet/mcp-r} \\
Each call into R, its tables and models & a temporary folder, removed when the window closes \\""")
patch(EN, "trouble: red model", r"""the meteorology is ticked and on the same time base as the target, lengthen the
        budget, or add estimators.""", r"""the meteorology is ticked and on the same time base as the target, raise the
        search trials, or try H2O.""")
patch(EN, "trouble: R", r"""  \item[``'rdata' is required but not installed''] \emph{Find stations} reads the UK
        archives with \code{rdata}, part of the \code{data} extra:
        \code{pip install "normet[data]"}. The installers include it.""", r"""  \item[``R was not found''] Install R, or point the window at \code{Rscript} with
        \tab{R $\rightarrow$ Locate Rscript\ldots}.
  \item[``the normet package could not be loaded''] Install it in R:
        \code{remotes::install\_github("apai-sys/normet-r")}; then
        \tab{R $\rightarrow$ Check R environment}.
  \item[``Neither lightgbm nor h2o loads in R''] \code{install.packages("lightgbm")}; H2O
        also needs Java.""")
patch(EN, "trouble: no Chronos-2", r"""  \item[Rolling and PDP are disabled] They need an AutoML model; the Chronos-2 backend
        has no response surface to vary.
  \item[Chronos-2 is greyed out] Install \code{normet[foundation]} (and
        \code{normet[finetune]} to fine-tune).
  \item[Chronos-2's verdict is red] Shuffling the weather barely moves its forecast: it is
        autoregressing. Check the meteorological columns, or use an AutoML backend.
""", "")
patch(EN, "trouble: similarity", r"""Placebo in space and by other estimators, or use fewer, better-chosen donors (the
        similarity ranking can help) or a longer pre-period.""", r"""Placebo in space and by other estimators, or use fewer, better-chosen donors or a
        longer pre-period.""")
patch(EN, "trouble: cancel", r"""  \item[A task runs too long] \emph{Cancel} frees the window at once; the computation
        finishes in the background and its result is discarded. Lower the samples, the
        budget, or the number of variables decomposed.""", r"""  \item[A task runs too long] \emph{Cancel} stops it, and the R process running it. Lower
        the samples, the search trials, or the number of variables decomposed.""")
patch(EN, "trouble: failed", r"""  \item[A task failed] The dialog shows its last line; the full traceback is in the
        \tab{Log} dock.""", r"""  \item[A task failed] The dialog shows R's error; the full traceback is in the
        \tab{Log} dock.""")

passage(EN, 'command log listing', r"""The session behind this manual's figures saves as""", r"""\section{Figures for publication}""",
        r"""The session behind this manual's figures saves as (the emission decomposition, the
multi-scale and partial-dependence calls left out):
\begin{lstlisting}[language=R]
# 21:32:48  Load example: London Marylebone Road NO2 (2020)
df <- my1

# 21:33:07  Train model
res <- nm_build_model(df, target = "NO2", backend = "lightgbm",
                      covariates = c("ws", "wd", "temp", "RH", "atmos_pres", "blh",
                                     "tcc", "tp", "ssrd", "date_unix", "day_julian",
                                     "weekday", "hour"),
                      split_method = "random", train_fraction = 0.75,
                      model_config = list(n_trials = 10), seed = 7654321)
df_prep <- res$df_prep
model <- res$model

# 21:34:58  Normalise
normalised <- nm_normalise(df_prep, model,
                           resample_vars = c("ws", "wd", "temp", "RH", "atmos_pres",
                                             "blh", "tcc", "tp", "ssrd"),
                           n_samples = 300, seed = 7654321,
                           return_quantiles = c(0.05, 0.25, 0.75, 0.95))
fig_normalise <- nm_plot_normalise(normalised, ci_low = "q050", ci_high = "q950")
if (interactive()) print(fig_normalise)

# 21:46:18  Decompose
decomposition <- nm_decompose("meteorology", df = df_prep, model = model,
                              target = "value",
                              covariates = c(...the same 13...),
                              n_samples = 100, seed = 7654321,
                              groups = list(Wind = c("ws", "wd"),
                                            `Temperature and humidity` = c("temp", "RH"),
                                            `Boundary layer and pressure` = c("atmos_pres", "blh"),
                                            `Sky and rain` = c("tcc", "tp", "ssrd")))
fig_decomposition <- nm_plot_decomposition_stack(decomposition)
if (interactive()) print(fig_decomposition)

# 21:47:17  Rolling normalisation
rolled <- nm_rolling(df_prep, model = model, covariates = c(...),
                     resample_vars = c(...the nine...),
                     window_days = 14, rolling_every = 7, n_samples = 50,
                     seed = 7654321)
fig_rolled <- nm_plot_rolling(rolled, data = df_prep)
if (interactive()) print(fig_rolled)
\end{lstlisting}
Run again with \code{Rscript}, or \code{source()} in R, it gives the same model and the
same results: every call carries its seed, and the LightGBM search runs a fixed number of
trials rather than for a time.

""")


# == the Chinese book (normet_manual_zh.tex): the same patches, in its words =====================

patch(ZH, "header", r"""% 截图：docs/manual/make_figures.py，NORMET_UI_LANGUAGE=zh 时存入 figures_zh/；
%       没有中文截图的取 figures/。""", r"""% 截图：gui/tools/walk_gui.py，NORMET_UI_LANGUAGE=zh 时存入 figures_zh/；
%       没有中文截图的取 figures/。
% 本书是 normet-py 的手册，由 gui/tools/vendor_py_gui.py 和 gui/tools/manual_patches.py
% 中的补丁改写为 normet R 包的窗口。""")
patch(ZH, "running head", r"""\fancyhead[L]{\small normet 用户手册}""", r"""\fancyhead[L]{\small normet 用户手册（R）}""")
patch(ZH, "title", r"""{\large\bfseries 用户手册\par}""", r"""{\large\bfseries 用户手册\par}
\vspace{0.2cm}
{\large normet R 包的窗口\par}""")
patch(ZH, "title blurb", r"""{\large 一个桌面应用和 Python 库：从空气质量记录中去除天气的影响，\\
并回答一项干预究竟改变了什么。\par}""", r"""{\large 一个 R 包及其桌面窗口：从空气质量记录中去除天气的影响，\\
并回答一项干预究竟改变了什么。\par}""")
patch(ZH, "what is normet", r"""\nm{} 是一个用于分析环境时间序列（首先是空气质量记录）的桌面应用和 Python 库。""",
      r"""\nm{} 是一个用于分析环境时间序列（首先是空气质量记录）的 R 包，附有桌面窗口。""")
patch(ZH, "calls into R", r"""窗口里的每一个操作都是对 \nm{} Python 包的一次调用；这些调用可以写成脚本、在命令行运行，
或通过模型上下文协议（MCP）由 AI 助手驱动（第\ref{ch:script}章）。窗口会记下它做的每一次
调用，因此靠点击完成的分析可以保存为一个能重复它的脚本（第~\ref{sec:commandlog}~节）。""",
      r"""窗口里的每一个操作都是对 \nm{} R 包的一次调用，由 \code{Rscript} 在单独的 R 进程中运行；
同样的函数可以写成 R 脚本，或通过模型上下文协议（MCP）由 AI 助手驱动（第\ref{ch:script}章）。
窗口会记下它做的每一次调用，因此靠点击完成的分析可以保存为一个能重复它的 R 脚本
（第~\ref{sec:commandlog}~节）。窗口就是 normet-py 的窗口，逐屏相同；它运行的是 R。""")
patch(ZH, "features: training", r"""  \item 用 FLAML（在时间预算内搜索估计器）或调参的 LightGBM 进行 AutoML 训练，以 $R^2$、
        RMSE 及另外九项统计量报告留出集上的拟合。""", r"""  \item 用 LightGBM（随机超参数搜索）或 H2O AutoML（在时间预算内搜索算法）训练，以 $R^2$、
        RMSE 及另外九项统计量报告留出集上的拟合。""")
patch(ZH, "features: no Chronos-2", r"""  \item 用 Chronos-2 时间序列基础模型零样本去气象化，结果格式相同——无需训练。
""", "")
patch(ZH, "figures made by", r"""图均为真实窗口的截图，由 \code{docs/manual/make\_figures.py} 在 \nm{} 自带的记录上生成：""",
      r"""图均为真实窗口的截图，由 \code{gui/tools/walk\_gui.py} 在 \nm{} 自带的记录上生成：""")
patch(ZH, "a run of your own", r"""你自己运行的结果会
在最后一两位上有所不同：AutoML 搜索以墙钟时间为界，两次访问的候选模型不会完全一样。""",
      r"""你自己运行的结果应当
与之非常接近：LightGBM 的搜索和每次抽样都带有种子，只是 LightGBM 的多线程可能改变最后一位。""")

passage(ZH, "installation", r"""% ============================ 2. INSTALLATION ===============================""",
        r"""% ============================ 3. METHODOLOGY =================================""", r"""% ============================ 2. INSTALLATION ===============================
\chapter{安装}\label{ch:install}

窗口运行的是 \nm{} R 包，所以先装 R 和这个包，再装窗口：安装包，或从仓库安装。

\section{R 和 normet 包}
\nm{} 需要 R~4.1 或更高版本。在 R 中：
\begin{lstlisting}[language=R]
install.packages(c("remotes", "lightgbm"))
remotes::install_github("apai-sys/normet-r")
install.packages("h2o")      # optional: the H2O AutoML backend (needs Java)
\end{lstlisting}
LightGBM 是默认后端。H2O AutoML 是可选的，需要 Java 运行时；运行 H2O 步骤时窗口启动它的
集群，窗口关闭时把它关掉。窗口在 \code{PATH} 上或 R 的安装位置找到 \code{Rscript}；
\tab{R $\rightarrow$ 定位 Rscript…}可以指定另一个，\tab{R $\rightarrow$ 检查 R 环境}会重新
查看是哪个 R、哪个版本的 \nm{}、有哪些后端。状态栏显示 R 的版本，其工具提示显示 \nm{} 的
版本和能载入的后端；缺少什么时，一条通知会说明应安装什么。

\section{macOS}
打开 \code{Normet-1.0.0-macos-arm64.dmg}，把 \code{Normet.app} 拖到\code{应用程序}文件夹。
应用自带 Python 和 Qt，但不带 R：它运行本机已安装的 R。首次启动比之后慢，因为要建立字体
缓存，之后的启动会复用它（保存在 \code{\textasciitilde/.normet/matplotlib}）；期间会显示启动画面。

\note{应用没有用 Apple 开发者 ID 签名。第一次打开时，请右键点击 \code{Normet.app}，选择
\emph{打开}，再在对话框中确认；只需一次。也可以在终端运行
\code{xattr -dr com.apple.quarantine /Applications/Normet.app}。}

\section{Windows 和 Linux}
在 Windows 上运行 \code{normet-setup-1.0.0.exe}，这是一个 Inno~Setup 安装向导，会添加开始
菜单快捷方式和可选的桌面快捷方式。安装程序未签名，所以首次运行时 SmartScreen 会显示
\emph{Windows 已保护你的电脑}：选择\emph{更多信息} $\rightarrow$ \emph{仍要运行}。在 Linux
上下载 \code{Normet-1.0.0-x86\_64.AppImage}，赋予可执行权限（\code{chmod +x}）后运行。在
精简的发行版上，Qt 可能需要 \code{libegl1 libgl1 libxkbcommon0 libdbus-1-3 libxcb-cursor0}。

安装包由仓库的 \code{build-gui.yml} 工作流构建（每个操作系统一个；PyInstaller 不能交叉
编译），附在其运行记录的 \emph{Actions $\rightarrow$ Artifacts} 下。
\code{gui/packaging/README.md} 说明了如何在本地构建。

\section{从仓库安装}
窗口是仓库 \code{gui} 文件夹中的一个 Python 包，需要 Python~3.10 或更高版本：
\begin{lstlisting}[language=bash]
python -m venv .venv && source .venv/bin/activate
pip install "git+https://github.com/apai-sys/normet-r#subdirectory=gui"
normet-r-gui                         # or: normet-r-gui mydata.csv
\end{lstlisting}
它的扩展 \code{geo} 增加 Shapely 和 pyshp，供传输工作室从 GeoJSON 或 Shapefile 文件读取源区。

""")

patch(ZH, "prepare", r"""训练模型之前，表格按以下顺序经过 \code{prepare\_data}：""", r"""训练模型之前，表格按以下顺序经过 \code{nm\_prepare\_data}：""")
passage(ZH, "training", r"""\section{训练模型}\label{sec:train}""", r"""\subsection{模型统计量}\label{sec:modstats}""",
        r"""\section{训练模型}\label{sec:train}
\nm{}（默认）训练梯度提升树，把预测变量映射到目标。提供两种后端：
\begin{description}\nosep
  \item[LightGBM]（默认）LightGBM 加上固定\emph{次数}的随机超参数搜索，每次用交叉验证评分
        （库中 50 次，窗口中 20 次）。
  \item[H2O AutoML] 在墙钟\emph{时间预算}（\code{max\_runtime\_secs}，60~s）内对所勾选的算法
        做 AutoML 搜索（默认只有 GBM；可以加入 DRF、GLM、深度学习、XGBoost 和堆叠集成），
        运行在本地的 H2O 集群上。
\end{description}
LightGBM 的搜索带有种子，所以同一脚本在同一数据上找到同一个模型。由于 H2O 的预算是墙钟时间，
同一脚本在更繁忙的机器上可能停在不同的候选模型上；若要以模型个数而非时间为界，请在
\code{model\_config} 中设置 \code{max\_models}。

""")
patch(ZH, "modstats", r"""\code{modStats} 分别预测训练行、测试行和全部行""", r"""\code{nm\_modStats} 分别预测训练行、测试行和全部行""")
patch(ZH, "normalise_auto", r"""\code{normalise\_auto} 会替你选择 $N$""", r"""\code{nm\_normalise\_auto} 会替你选择 $N$""")
patch(ZH, "conditional pool", r"""\code{conditional\_on} 把重采样池限制在满足
条件的行——一个值、一组值或该列的一个函数，例如 \code{\{"ws": lambda v: v < 2\}} 只从静风
时段中抽取。\code{resample\_pools} 让某些变量从各自的池中抽取：
\code{\{"transport": clean\_hours[traj\_cols]\}} 从清洁气团时段中抽取轨迹特征""",
      r"""\code{conditional\_on}（\code{nm\_normalise\_ext} 的参数）
把重采样池限制在满足条件的行——一个值、一组值或该列的一个函数，例如
\code{list(ws = function(v) v < 2)} 只从静风时段中抽取。\code{resample\_pools} 让某些变量从
各自的池中抽取：\code{list(transport = clean\_hours[traj\_cols])} 从清洁气团时段中抽取轨迹特征""")
patch(ZH, "seed", r"""\paragraph{可重复性。}抽样带有种子（默认 \code{seed=7654321}）""", r"""\paragraph{可重复性。}抽样带有种子（默认 \code{seed = 7654321}）""")
patch(ZH, "groups", r"""\paragraph{分组。}\code{groups=\{"local": met\_cols, "transport": traj\_cols\}} 为每个分组""",
      r"""\paragraph{分组。}\code{groups = list(local = met\_cols, transport = traj\_cols)} 为每个分组""")
patch(ZH, "rolling", r"""\code{rolling} 逐窗口地归一化记录""", r"""\code{nm\_rolling} 逐窗口地归一化记录""")
passage(ZH, "no Chronos-2", r"""\section{用 Chronos-2 零样本去气象化}\label{sec:chronos}""",
        r"""\section{合成控制}\label{sec:scmtheory}""", "")
patch(ZH, "mlscm", r"""  \item[\code{mlscm}] ML 增广 SCM（\emph{实验性}）：一个 AutoML 模型在干预前时段把供体的""",
      r"""  \item[\code{mlscm}] ML 增广 SCM（\emph{实验性}）：一个 LightGBM 或 H2O 模型在干预前时段把供体的""")
patch(ZH, "bayesian", r"""  \item[\code{bayesian}] 贝叶斯单纯形 SCM（PyMC）：权重取 Dirichlet 先验，直接给出后验
        可信区间。""", r"""  \item[\code{bayesian}] 贝叶斯单纯形 SCM：权重取平坦的 Dirichlet 先验，用马尔可夫链
        蒙特卡洛抽样，直接给出后验可信区间。""")
patch(ZH, "diagnostics", r"""\code{scm\_diagnostics} 报告干预前的拟合""", r"""\code{nm\_scm\_diagnostics} 报告干预前的拟合""")
patch(ZH, "noise fits", r"""拟合得 $R^2 = -0.05$，20 个得 0.69，53 个得 0.997；经典 SCM 用 40 个随机游走供体拟合 12 个
月，对打乱的序列也能得到 0.60。因此""", r"""拟合得 $R^2 = 0.06$，20 个得 0.81，53 个得 0.999。因此""")
patch(ZH, "conformal", r"""  \item[共形区间] \code{conformal\_effect\_interval} 给出干预后平均效应的有限样本区间
        （Chernozhukov、W\"uthrich 和 Zhu，2021）；\code{rmspe\_ratio\_test} 给出 Abadie""",
      r"""  \item[共形区间] \code{nm\_conformal\_effect\_interval} 给出干预后平均效应的有限样本区间
        （Chernozhukov、W\"uthrich 和 Zhu，2021）；\code{nm\_rmspe\_ratio\_test} 给出 Abadie""")

patch(ZH, "my1", r"""（即下表的
        \code{load\_my1()}）。""", r"""（即下表的
        \code{my1}）。""")
patch(ZH, "my1_pm25", r"""\PMtwo{}，配以本站的风和温度以及 ERA5 的其他字段（\code{load\_my1\_pm25()}）。""",
      r"""\PMtwo{}，配以本站的风和温度以及 ERA5 的其他字段（\code{my1\_pm25}）。""")
passage(ZH, "data sets", r"""\nm{} 模型描述论文中的真实记录随包提供；在脚本中这样载入：""",
        r"""数据来源：英国 AURN""", r"""\nm{} 模型描述论文中的真实记录作为包的数据集随包提供（在脚本中 \code{library(normet)} 之后
即可用 \code{my1}）：
\begin{center}\small
\begin{tabular}{@{}lp{7.0cm}p{3.2cm}@{}}
\toprule
数据集 & 内容 & 用于 \\
\midrule
\code{my1}      & 伦敦 Marylebone Road 逐时 \NOtwo{} + ERA5 气象，2020 年 1--8 月 & 去气象化 \\
\code{scm}      & 104 个英国站点的月均去气象化 \NOtwo{}，2016--2021 & 合成控制（ULEZ） \\
\code{my1\_pm25} & MY1 逐时 \PMtwo{} + 气象，2020 年 1--8 月 & 考虑传输的案例 \\
\code{traj\_my1} & 到达 MY1 的 6 小时一次的 HYSPLIT 轨迹特征 & 考虑传输的案例 \\
\code{extdata/traj} & 两天的原始 HYSPLIT \code{tdump} 文件（\code{system.file("extdata", "traj", package = "normet")}） & 传输工作室 \\
\bottomrule
\end{tabular}
\end{center}
""")

patch(ZH, "model page", r"""  \item[模型] 后端、划分、训练集比例、时间预算（或搜索次数）、估计器、随机种子；Chronos-2
        则换成设备和微调（第\ref{ch:train}章）。""", r"""  \item[模型] 后端、划分、训练集比例、搜索次数（H2O 则为时间预算和算法）、随机种子
        （第\ref{ch:train}章）。""")
patch(ZH, "run buttons", r"""训练模型 / 载入 Chronos-2 & 一张表，至少勾选一个预测变量 & \code{build\_model} \\
微调 Chronos-2        & 已载入 Chronos-2         & \code{finetune} \\
运行归一化            & 一个模型，至少一个重采样变量 & \code{normalise} \\
运行分解              & 一个模型                 & \code{decompose} \\
运行滚动归一化        & 一个 AutoML 模型         & \code{rolling} \\
多尺度分解            & 一个 AutoML 模型，一次归一化 & \code{rolling} $\times 3$ \\
趋势检验              & 一个 AutoML 模型（有分解时检验分解的序列） & \code{trend}（1 段）/\code{detect\_trend\_breaks}（更多） \\
计算 PDP              & 一个 AutoML 模型，至少勾选一个变量 & \code{pdp} \\""",
      r"""训练模型              & 一张表，至少勾选一个预测变量 & \code{nm\_build\_model} \\
运行归一化            & 一个模型，至少一个重采样变量 & \code{nm\_normalise} \\
运行分解              & 一个模型                 & \code{nm\_decompose} \\
运行滚动归一化        & 一个模型                 & \code{nm\_rolling} \\
多尺度分解            & 一个模型，一次归一化     & \code{nm\_rolling} $\times 3$ \\
趋势检验              & 一个模型（有分解时检验分解的序列） & \code{nm\_trend}（1 段）/\code{nm\_trend\_breaks}（更多） \\
计算 PDP              & 一个模型，至少勾选一个变量 & \code{nm\_pdp} \\""")
patch(ZH, "trend breaks name",
      r"""\emph{分段拟合}——即对所选序列运行 \code{detect\_trend\_breaks}。""",
      r"""\emph{分段拟合}——即对所选序列运行 \code{nm\_trend\_breaks}。""")
patch(ZH, "trend script names",
      "（脚本里是 \\code{trend\\_breaks\\_call}，不是\n\\code{trend\\_call}）",
      "（脚本里是 \\code{nm\\_trend\\_breaks}，不是\n\\code{nm\\_trend}）")
patch(ZH, "trend breaks caption",
      r"""\screenshot{ui_trend_breaks.png}{段数 2、对 MY1 分离出的长期趋势的分段拟合：搜索在 2020-03-18 19:00（2020-03-23
封控的前奏）找到断点——相对单段的 SSE 下降 88.7\,\%，搜索的块自助法 p 为 0.001，要引用的是它。第 1 段
斜率 +0.0812 每天（95\,\% [0.0761, 0.0863]），第 2 段降到 $-$0.0121 每天（95\,\% [$-$0.0134, $-$0.0108]）。
图上方的评估结论和每段一行的表格就是\tab{趋势}标签页的内容。}{fig:trend_breaks}""",
      r"""\screenshot{ui_trend_breaks.png}{段数 2、对 MY1 分离出的长期趋势的分段拟合：搜索在 2020-03-25 20:00（2020-03-23
封控开始两天后）找到断点——相对单段的 SSE 下降 79.6\,\%，搜索的块自助法 p 为 0.001，要引用的是它。第 1 段
斜率 +0.03562 每天（95\,\% [0.03173, 0.03937]），第 2 段放缓到 +0.00512 每天（95\,\% [0.00362, 0.00660]）。
图上方的评估结论和每段一行的表格就是\tab{趋势}标签页的内容。}{fig:trend_breaks}""")
patch(ZH, "task clock", r"""任务能说出自己的进度时——滚动窗口、分解的各步、LightGBM 的各次试验、HYSPLIT 的各个受体时刻、
FLAML 的时间预算——进度条随之推进，""", r"""任务能说出自己的进度时——R 报告蒙特卡罗的各批、滚动窗口、分解的各步、LightGBM 的各次
试验和 HYSPLIT 的各个受体时刻；H2O 则按已用时间与其时间预算之比——进度条随之推进，""")
patch(ZH, "cancel", r"""取消会\emph{放弃}该任务：窗口立刻空出来，但计算无法中断，它会在后台跑完，
结果被丢弃。""", r"""取消会停止该任务：执行它的 R 进程连同它启动的东西（比如一次 HYSPLIT 运行）
被终止，窗口立刻空出来。""")
patch(ZH, "R menu", r"""帮助     & 用户手册                             & F1 \\""", r"""R        & 定位 Rscript…、检查 R 环境、将图另存为 R 脚本… & \\
帮助     & 用户手册                             & F1 \\""")
patch(ZH, "log dock", r"""它可以一直开在主窗口旁边：
每一步做了什么、多少行、FLAML 选中的估计器及其超参数、一次滚动运行生成了多少窗口。""",
      r"""它可以一直开在主窗口旁边：
每一次对 R 的调用（\code{R> nm\_normalise(…)}）和 R 自己的日志——每一步做了什么、多少行、
LightGBM 的搜索次数、一次滚动运行生成了多少窗口。""")
patch(ZH, "failed task", r"""任务失败时，完整的回溯写在日志里，最后一行显示在对话框中。""",
      r"""任务失败时，R 的错误连同回溯写在日志里，并显示在对话框中。""")

passage(ZH, "settings", r"""\section{设置}
\begin{description}\nosep
  \item[后端] \code{flaml}""", r"""\section{阅读模型标签页}""", r"""\section{设置}
\begin{description}\nosep
  \item[后端] \code{lightgbm}（默认）或 \code{h2o}。H2O 需要 Java 和 \code{h2o} R 包；
        \tab{R $\rightarrow$ 检查 R 环境}会说明它能否载入。
  \item[划分方法、训练集比例] 见第~\ref{sec:split}~节；默认 0.75。
  \item[搜索次数] LightGBM 的随机搜索次数，默认 20。对 H2O，这一行变为\emph{时间预算}，默认
        60~s；切换后端时各自的值会被保留。
  \item[算法]（仅 H2O）默认只有 GBM；加入更多以扩大搜索范围。
  \item[随机种子] 默认 7654321：划分和搜索都以它为种子。
\end{description}

""")
patch(ZH, "train runs", r"""\emph{训练模型}运行 \code{build\_model}——准备数据、划分和搜索——""",
      r"""\emph{训练模型}运行 \code{nm\_build\_model}——准备数据、划分和搜索——""")
patch(ZH, "model table", r"""表格是训练行、测试行和全部行的 \code{modStats}""", r"""表格是训练行、测试行和全部行的 \code{nm\_modStats}""")
patch(ZH, "importance", r"""条形图是模型的特征重要性（LightGBM 为分裂次数）。""", r"""条形图是模型的特征重要性（各预测变量在 LightGBM 增益中所占的份额）。""")
patch(ZH, "model caption", r"""\screenshot{ui_model.png}{用 FLAML（LightGBM，30~s 预算，随机划分）训练 MY1：在 1,448 个
留出小时上 $R^2 = 0.883$、RMSE $= 8.66$~\ugm{}，而在 4,345 个训练小时上为 $0.976$。风向和
风速、边界层高度和趋势承担了最多的分裂。}{fig:model}""", fill(r"""\screenshot{ui_model.png}{用 LightGBM（10 次搜索，随机划分）训练 MY1：在 @test_n@ 个
留出小时上 $R^2 = @test_r2@$、RMSE $= @test_rmse@$~\ugm{}，而在 @train_n@ 个训练小时上为 $@train_r2@$。
日历——一年中的第几天、趋势和小时——以及风向承担了最多的增益。}{fig:model}"""))
patch(ZH, "a poor fit", r"""试试更多预测变量、更长的预算或更多估计器。""", r"""试试更多预测变量、更多搜索次数，或用 H2O。""")
passage(ZH, "no Chronos-2 settings", r"""\section{Chronos-2}\label{sec:chronosui}""",
        r"""% ============================ 7. NORMALISATION ================================""", "")

patch(ZH, "samples", r"""  \item[样本数] 蒙特卡洛抽样次数，默认 300（Chronos-2 为 8；多少次才够见
        第~\ref{sec:normalise}~节）。""", r"""  \item[样本数] 蒙特卡洛抽样次数，默认 300（多少次才够见第~\ref{sec:normalise}~节）。""")
patch(ZH, "cycle profiles", r"""用脚本表示：\code{nm.cycle\_profiles(result, ["observed",
"normalised"])}。""", r"""用 R 表示：\code{nm\_cycle\_profiles(result, c("observed",
"normalised"))}。""")
patch(ZH, "normalise numbers", r"""是 $-0.26$~\ugm{}，因为八个月下来""", fill(r"""是 @norm_diff@~\ugm{}，因为八个月下来"""))
patch(ZH, "monthly means", r"""观测     & 60.3 & 65.2 & 51.7 & 34.5 & 30.7 & 35.1 & 31.6 & 36.6 \\
归一化   & 59.7 & 64.7 & 54.0 & 34.7 & 32.1 & 32.5 & 32.1 & 33.8 \\""", fill(r"""观测     & @obs@ \\
归一化   & @norm@ \\"""))
patch(ZH, "spring drop", r"""从 2 月到 4 月，归一化序列下降了 30.0~\ugm{}（46\,\%），观测下降了 30.7~\ugm{}：春季的
下降几乎都不是天气造成的。3 月的天气比通常更清洁（观测比归一化低 2.3），6 月和 8 月则更脏。""",
      fill(r"""从 2 月到 4 月，归一化序列下降了 @feb_apr_norm@（@feb_apr_pct@），观测下降了 @feb_apr_obs@：春季的
下降几乎都不是天气造成的。3 月的天气比通常更清洁（观测比归一化低 @mar_cleaner@），6 月和 8 月则更脏。"""))
patch(ZH, "no Chronos-2 rows", r"""\note{在 Chronos-2 上，前 \code{context\_length} 行用观测值填入；它们在图上以灰色阴影标出，
图下方的一行说明有多少行，均值只在其余的行上计算。}

""", "")
patch(ZH, "emission caption", r"""43.1~\ugm{}）。封控同时表现为趋势（$\sigma = 9.56$）和季节分量（$\sigma = 4.74$）中的
台阶：一次性事件不是季节，而记录太短，无法把二者分开。日变化（右）最大
（$\sigma = 9.92$）""", fill(r"""@emi_base@~\ugm{}）。封控同时表现为趋势（$\sigma = @emi_trend@$）和季节分量（$\sigma = @emi_season@$）中的
台阶：一次性事件不是季节，而记录太短，无法把二者分开。日变化（右）最大
（$\sigma = @emi_diurnal@$）"""))
patch(ZH, "weekly", r"""星期循环（$\sigma = 3.36$）在周末下降。""", fill(r"""星期循环（$\sigma = @emi_weekly@$）在周末下降。"""))
patch(ZH, "met caption", r"""$\sigma = 16.79$~\ugm{}）按精确 Shapley 值（16 个联盟）分摊到四个分组：风（\code{ws}、
\code{wd}；$\sigma = 9.92$）、热力（\code{temp}、\code{RH}；5.24）、混合（\code{blh}、
\code{atmos\_pres}；4.89）和天空（\code{tcc}、\code{tp}、\code{ssrd}；3.44）。}{fig:metdecomp}""",
      fill(r"""$\sigma = @met_total@$~\ugm{}）按精确 Shapley 值（16 个联盟）分摊到四个分组：风（\code{ws}、
\code{wd}；$\sigma = @met_wind@$）、热力（\code{temp}、\code{RH}；@met_thermo@）、混合（\code{blh}、
\code{atmos\_pres}；@met_mixing@）和天空（\code{tcc}、\code{tp}、\code{ssrd}；@met_sky@）。}{fig:metdecomp}"""))
patch(ZH, "multiscale caption", r"""$\sigma \approx 3.0$），其次是季节内和慢频带。""", fill(r"""$\sigma \approx @ms_fast@$），其次是季节内和慢频带。"""))

patch(ZH, "ULEZ in R", r"""\begin{lstlisting}[language=Python]
import normet as nm
scm_df = nm.datasets.load_scm()
df = scm_df.query("'2017-01-01' <= date < '2020-03-01'")
df = df[df["type"].str.contains("Traffic")]
counts = df.dropna(subset=["NO2_dw"]).groupby("code").size()
donors = [c for c in counts[counts == df["date"].nunique()].index if c != "MY1"]
df = df[df["code"].isin(donors + ["MY1"])]
df.to_csv("ulez_panel.csv", index=False)
\end{lstlisting}""", r"""\begin{lstlisting}[language=R]
library(normet)
df <- subset(scm, date >= as.Date("2017-01-01") & date < as.Date("2020-03-01"))
df <- df[grepl("Traffic", df$type), ]
counts <- table(df$code[!is.na(df$NO2_dw)])
donors <- setdiff(names(counts)[counts == length(unique(df$date))], "MY1")
df <- df[df$code %in% c(donors, "MY1"), ]
write.csv(df, "ulez_panel.csv", row.names = FALSE)
\end{lstlisting}""")
patch(ZH, "similarity", r"""  \item[按相似度排列供体]（需要 \code{foundation} 扩展）用 Chronos-2 嵌入每个单元干预前的
        记录，按其动态与处理单元的余弦相似度对其他单元排序，显示在\tab{相似度}标签页上；
        \emph{勾选前 N 个}和\emph{应用}把它们设为供体池。
""", "")
patch(ZH, "ML backend", r"""\emph{后端}选择估计器（第~\ref{sec:scmtheory}~节）；\emph{机器学习后端}和\emph{时间预算}
（15~s）用于 \code{mlscm}，\emph{抽样次数}（1000）用于 \code{bayesian}。""",
      r"""\emph{后端}选择估计器（第~\ref{sec:scmtheory}~节）；\emph{机器学习后端}（\code{lightgbm} 或
\code{h2o}）和\emph{搜索次数}（5；H2O 则为\emph{时间预算}，15~s）用于 \code{mlscm}，
\emph{抽样次数}（1000）用于 \code{bayesian}。""")
patch(ZH, "fit caption", r"""ATT $= -18.14$~\ugm{}。干预前""", fill(r"""ATT $= @scm_att@$~\ugm{}。干预前"""))
patch(ZH, "top donor", r"""它权重最大的
供体占 99.5\,\%（$\text{HHI} = 0.99$）""", r"""它权重最大的
供体占全部权重（$\text{HHI} = 1.00$）""")
patch(ZH, "scm row", r"""\code{scm}    & 0.999  & 1.000   & 0.16  & $-18.14$ \\""", fill(r"""\code{scm}    & 0.999  & 1.000   & 0.16  & $@scm_att@$ \\"""))
patch(ZH, "bands caption", r"""平均效应为 $-18.14$~\ugm{}，""", fill(r"""平均效应为 $@scm_att@$~\ugm{}，"""))

patch(ZH, "multisite", r"""或在脚本中用 \code{do\_all\_multisite} 处理。""", r"""或在脚本中用 \code{nm\_do\_all\_multisite} 处理。""")
patch(ZH, "read_time_series", r"""在脚本中，
\code{nm.io.read\_time\_series(path, zone=\ldots)} 以同样的方式读表。""", r"""在 R 中，
\code{nm\_read\_time\_series(path, zone = \ldots)} 以同样的方式读表。""")
patch(ZH, "CDS", r"""Copernicus CDS（需要
        \code{\textasciitilde/.cdsapirc}）。""", r"""Copernicus CDS（需要
        \code{ecmwfr} R 包和用 \code{ecmwfr::wf\_set\_key} 设置的 CDS 密钥）。""")
patch(ZH, "openair", r"""这些档案就是 R 的 \code{importUKAQ()} 读取的 openair \code{.RData} 文件，不经 R 直接解析，
所以数据与 openair 工作流一致。数据工作室需要联网；从它发送来的表保存在内存中，命令日志会
如实说明这一点，而不是写一条无法重复的 \code{read\_csv}。""", r"""这些档案就是 R 的 \code{importUKAQ()} 读取的 openair \code{.RData} 文件，由 R 包读取
（\code{nm\_fetch\_ukaq\_measurements}），所以数据与 openair 工作流一致。数据工作室需要联网；
从它发送来的表保存在内存中，命令日志会如实说明这一点，而不是写一条无法重复的
\code{nm\_read\_time\_series}。""")
patch(ZH, "polar", r"""用脚本表示：
\code{nm.polar\_plot(df, target="NO2", ws\_col="ws", wd\_col="wd")}。""", r"""用 R 表示：
\code{nm\_plot\_polar(df, target = "NO2", ws\_col = "ws", wd\_col = "wd")}。""")

patch(ZH, "report provenance", r"""时间、平台和 Python 版本""", r"""时间、平台和 R 版本""")
patch(ZH, "script is R", r"""把它写成一个能重复本次会话的 Python 文件，\emph{清空}清空日志。""",
      r"""把它写成一个能重复本次会话的 R 脚本，\emph{清空}清空日志。

窗口用 matplotlib 绘图；R 包用 ggplot2 绘制同样的结果。因此每个结果的条目最后都是 R 包绘制它的
图——\code{fig\_normalise <- nm\_plot\_normalise(normalised)}，其他结果则是
\code{nm\_plot\_decomposition\_stack}、\code{nm\_plot\_rolling} 和
\code{nm\_plot\_pdp\_grid}——在 R 或 RStudio 中运行脚本时画出（\code{Rscript} 下不画），可像任何 ggplot 一样修改。
\tab{R $\rightarrow$ 将图另存为 R 脚本…}把当前标签页显示的结果（归一化、分解——所显示的方法——、
滚动或 PDP）存为 CSV，并在旁边写出读取它、如此绘图并保存为 PDF 的 R 代码：不必重新训练模型，
就能在 R 中修改图。""")
patch(ZH, "saved session", r"""Chronos-2 检查点不
写入（它是预训练模型，约 500~MB）：要继续请重新载入。会话文件是 Python pickle：只打开你自己
或本窗口写出的文件。""", r"""会话文件是 Python
pickle，其中带有 R 模型的文件夹，所以能在另一台机器上打开：只打开你自己或本窗口写出的文件。""")
patch(ZH, "session script", r"""以及按它所做的调用设置好的参数面板。
脚本是 Python，会按原样运行，所以窗口会先询问。""", r"""以及按它所做的调用设置好的参数面板——在运行之前由 R 自己的解析器读出。脚本是 R，会在 R
中、从它保存所在的文件夹按原样运行（所以它按相对路径读取的表能被找到）；窗口会先询问。""")
patch(ZH, "methods caption", r"""记录、FLAML 模型及其留出集拟合""", r"""记录、LightGBM 模型及其留出集拟合""")

passage(ZH, "scripting", r"""% ============================ 15. SCRIPTING ===================================""",
        r"""% ============================ APPENDICES ======================================""", r"""% ============================ 15. SCRIPTING ===================================
\chapter{脚本：R 和 MCP}\label{ch:script}

\section{R 包}
窗口做的每件事都是 \nm{} R 包的一个函数。一次调用的流水线完成准备、训练和归一化：
\begin{lstlisting}[language=R]
library(normet)

met <- c("ws", "wd", "temp", "RH", "atmos_pres", "blh", "tcc", "tp", "ssrd")
predictors <- c(met, "date_unix", "day_julian", "weekday", "hour")

res <- nm_do_all(my1, target = "NO2", backend = "lightgbm",
                 covariates = predictors, resample_vars = met,
                 n_samples = 300, n_cores = 4)
nm_modStats(res$df_prep, res$model)   # training, testing and all rows
\end{lstlisting}
逐步进行：
\begin{lstlisting}[language=R]
built <- nm_build_model(my1, target = "NO2", backend = "lightgbm",
                        covariates = predictors, model_config = list(n_trials = 20))
df_prep <- built$df_prep
model <- built$model
norm <- nm_normalise(df_prep, model, resample_vars = met, n_samples = 300,
                     return_quantiles = c(0.025, 0.975))
auto <- nm_normalise_auto(df_prep, model, resample_vars = met)   # stops when converged
emi <- nm_decompose("emission", df = df_prep, model = model, covariates = predictors)
mets <- nm_decompose("meteorology", df = df_prep, model = model,
                     covariates = predictors,
                     groups = list(wind = c("ws", "wd"), rest = met[-(1:2)]))
roll <- nm_rolling(df_prep, model, covariates = predictors, resample_vars = met)
curves <- nm_pdp(df_prep, model, var_list = c("ws", "temp"))
\end{lstlisting}
更多函数，均已导出：
\begin{center}\small
\begin{tabular}{@{}p{7.4cm}p{8.0cm}@{}}
\toprule
函数 & 作用 \\
\midrule
\code{nm\_do\_all\_unc}       & 在 \code{n\_models} 个种子上运行流水线，给出置信区间 \\
\code{nm\_do\_all\_multisite} & 逐站点流水线 \\
\code{nm\_cv\_score}          & 前向滚动交叉验证 \\
\code{nm\_run\_scm}, \code{nm\_scm\_all} & 一次合成控制；把每个单元都当作处理单元 \\
\code{nm\_placebo\_in\_space}, \code{nm\_placebo\_in\_time} & 安慰剂检验 \\
\code{nm\_uncertainty\_bands}, \code{nm\_effect\_bands\_space} & 刀切法/自助法区间和安慰剂区间 \\
\code{nm\_scm\_diagnostics}, \code{nm\_conformal\_effect\_interval} & 拟合诊断；共形区间 \\
\code{nm\_bayesian\_scm}      & 贝叶斯 SCM \\
\code{nm\_detect\_events}, \code{nm\_anomaly\_scores} & 归一化序列中的事件 \\
\code{nm\_plot\_normalise}, \code{nm\_plot\_decomposition\_stack}, \code{nm\_plot\_scm\_dashboard} & 图（ggplot2） \\
\code{nm\_make\_run}, \code{nm\_save\_run}, \code{nm\_generate\_html} & 溯源和报告 \\
\code{nm\_trend}               & 趋势检验及其块自助法修正（\tab{趋势}标签页，第~\ref{sec:trend}~节） \\
\code{nm\_trend\_breaks}       & 分段趋势：水平或斜率在哪处断掉（BIC + 块自助法门槛） \\
\code{nm\_decompose\_uncertainty} & 把总离散分摊到气象、模型形式及二者交互（\tab{不确定性}标签页，第~\ref{sec:uncertainty}~节） \\
\code{nm\_make\_cache}        & 磁盘缓存 \\
\bottomrule
\end{tabular}
\end{center}
每个函数的帮助页（\code{?nm\_normalise}）给出其参数和示例，\url{https://github.com/apai-sys/normet-r}
上的参考按领域列出它们。

\section{Rscript}\label{sec:cli}
这个包没有自己的命令：R 脚本用 \code{Rscript} 运行，命令日志保存的脚本就是一个
（第~\ref{sec:commandlog}~节）：
\begin{lstlisting}[language=bash]
Rscript normet_session.R        # repeats the window's session
\end{lstlisting}
\code{nm\_make\_run} 和 \code{nm\_save\_run} 把结果连同其溯源信息保存下来（一个 \code{.rds}
加一个 \code{.meta.json} 附属文件），\code{nm\_generate\_html} 可把它转成 HTML 报告。

\section{通过 MCP 使用 AI 助手}\label{sec:mcp}
\code{nm\_mcp\_server()} 通过模型上下文协议、经由 stdio 把 \nm{} 提供给 AI 助手：
\begin{lstlisting}[language=bash]
claude mcp add normet -- Rscript -e "normet::nm_mcp_server()"     # Claude Code
# Claude Desktop, claude_desktop_config.json:
#   {"mcpServers": {"normet": {"command": "Rscript",
#                              "args": ["-e", "normet::nm_mcp_server()"]}}}
\end{lstlisting}
它的工具就是 normet-py 的 \code{normet-mcp} 的工具，名字相同：助手可以列出示例、检查表格、
启动 do-all、分解、SCM 和交叉验证任务、跟踪和取消它们、读取运行或结果、画图和写报告。每个
任务是一个 R 脚本 \code{job.R}，由 \code{Rscript} 在它自己的文件夹（\code{\$NORMET\_MCP\_HOME}，
默认 \code{\textasciitilde/.normet/mcp-r}）中运行，所以脚本就是它的记录，不需要助手也能再次运行。
助手得到的是 \nm{} 对表格或结果的解读，而不是数据；只读取 \code{\$NORMET\_MCP\_ROOTS}（默认为
你的主文件夹）下的文件。服务器要求助手说明理由地提议目标、预测变量和供体池，让你确认，并且
只引用工具返回的数字。在 R 中，\code{nm\_agent\_tool()} 调用同样的工具。

""")

patch(ZH, "defaults: training", r"""FLAML 时间预算                 & 60 s & 90 s \\
FLAML 估计器                   & lgbm & lgbm \\
FLAML 指标                     & $R^2$ & $R^2$ \\
LightGBM 搜索次数              & 20 & --- \\""", r"""LightGBM 搜索次数              & 20 & 50，每次 5 折交叉验证 \\
H2O 时间预算                   & 60 s & 60 s \\
H2O 算法                       & GBM & GBM \\""")
patch(ZH, "defaults: samples", r"""归一化抽样次数                 & 300（Chronos-2：8） & 300（Chronos-2：8） \\""",
      r"""归一化抽样次数                 & 300 & 300 \\""")
patch(ZH, "defaults: auto", r"""\code{normalise\_auto}          & --- &""", r"""\code{nm\_normalise\_auto}       & --- &""")
patch(ZH, "defaults: no Chronos-2", r"""Chronos-2 上下文 / 预测长度    & 2048 / 168 行 & 2048 / 168 行 \\
""", "")
patch(ZH, "files: settings", r"""窗口几何、外观、语言、助手模型 & 系统的设置存储（\code{apai-sys/normet-gui}） \\""",
      r"""窗口几何、外观、语言、助手模型、Rscript & 系统的设置存储（\code{apai-sys/normet-r-gui}） \\""")
patch(ZH, "files: jobs", r"""MCP 任务                       & \code{\$NORMET\_MCP\_HOME}，默认 \code{\textasciitilde/.normet/mcp} \\
Chronos-2 权重                 & Hugging Face 缓存 \\""", r"""MCP 任务                       & \code{\$NORMET\_MCP\_HOME}，默认 \code{\textasciitilde/.normet/mcp-r} \\
每次对 R 的调用及其表格和模型  & 一个临时文件夹，窗口关闭时删除 \\""")
patch(ZH, "trouble: red model", r"""检查气象是否已勾选、与目标的时间基准
        是否一致，延长预算，或加入估计器。""", r"""检查气象是否已勾选、与目标的时间基准
        是否一致，增加搜索次数，或改用 H2O。""")
patch(ZH, "trouble: R", r"""  \item[“'rdata' is required but not installed”] \emph{查找站点}用 \code{rdata} 读取英国
        档案，它属于 \code{data} 扩展：\code{pip install "normet[data]"}。安装包已包含它。""",
      r"""  \item[“未找到 R”] 安装 R，或用\tab{R $\rightarrow$ 定位 Rscript…}指定 \code{Rscript}。
  \item[“无法载入 normet 包”] 在 R 中安装它：\code{remotes::install\_github("apai-sys/normet-r")}；
        然后\tab{R $\rightarrow$ 检查 R 环境}。
  \item[“R 中 lightgbm 和 h2o 都无法载入”] \code{install.packages("lightgbm")}；H2O 还需要 Java。""")
patch(ZH, "trouble: no Chronos-2", r"""  \item[滚动和 PDP 被禁用] 它们需要 AutoML 模型；Chronos-2 后端没有可供改变的响应面。
  \item[Chronos-2 呈灰色] 安装 \code{normet[foundation]}（微调还需 \code{normet[finetune]}）。
  \item[Chronos-2 的评估结论为红色] 打乱天气几乎不改变它的预测：它在做自回归。检查气象列，
        或改用 AutoML 后端。
""", "")
patch(ZH, "trouble: similarity", r"""或者用更少、更精选的供体（相似度排序可以帮忙），或者
        更长的干预前时段。""", r"""或者用更少、更精选的供体，或者更长的干预前时段。""")
patch(ZH, "trouble: cancel", r"""  \item[任务运行太久] \emph{取消}立刻释放窗口；计算在后台跑完，结果被丢弃。减少抽样次数、
        预算或分解的变量数。""", r"""  \item[任务运行太久] \emph{取消}停止它，连同运行它的 R 进程。减少抽样次数、搜索次数或
        分解的变量数。""")
patch(ZH, "trouble: failed", r"""  \item[任务失败] 对话框显示最后一行；完整的回溯在\tab{日志}停靠窗中。""",
      r"""  \item[任务失败] 对话框显示 R 的错误；完整的回溯在\tab{日志}停靠窗中。""")
passage(ZH, 'command log listing', r"""本手册各图背后的会话保存为""", r"""\section{打印用图}""",
        r"""本手册各图背后的会话保存为（省略了排放分解、多尺度和部分依赖的调用）：
\begin{lstlisting}[language=R]
# 21:32:48  Load example: London Marylebone Road NO2 (2020)
df <- my1

# 21:33:07  Train model
res <- nm_build_model(df, target = "NO2", backend = "lightgbm",
                      covariates = c("ws", "wd", "temp", "RH", "atmos_pres", "blh",
                                     "tcc", "tp", "ssrd", "date_unix", "day_julian",
                                     "weekday", "hour"),
                      split_method = "random", train_fraction = 0.75,
                      model_config = list(n_trials = 10), seed = 7654321)
df_prep <- res$df_prep
model <- res$model

# 21:34:58  Normalise
normalised <- nm_normalise(df_prep, model,
                           resample_vars = c("ws", "wd", "temp", "RH", "atmos_pres",
                                             "blh", "tcc", "tp", "ssrd"),
                           n_samples = 300, seed = 7654321,
                           return_quantiles = c(0.05, 0.25, 0.75, 0.95))
fig_normalise <- nm_plot_normalise(normalised, ci_low = "q050", ci_high = "q950")
if (interactive()) print(fig_normalise)

# 21:46:18  Decompose
decomposition <- nm_decompose("meteorology", df = df_prep, model = model,
                              target = "value",
                              covariates = c(...the same 13...),
                              n_samples = 100, seed = 7654321,
                              groups = list(Wind = c("ws", "wd"),
                                            `Temperature and humidity` = c("temp", "RH"),
                                            `Boundary layer and pressure` = c("atmos_pres", "blh"),
                                            `Sky and rain` = c("tcc", "tp", "ssrd")))
fig_decomposition <- nm_plot_decomposition_stack(decomposition)
if (interactive()) print(fig_decomposition)

# 21:47:17  Rolling normalisation
rolled <- nm_rolling(df_prep, model = model, covariates = c(...),
                     resample_vars = c(...the nine...),
                     window_days = 14, rolling_every = 7, n_samples = 50,
                     seed = 7654321)
fig_rolled <- nm_plot_rolling(rolled, data = df_prep)
if (interactive()) print(fig_rolled)
\end{lstlisting}
用 \code{Rscript} 再次运行，或在 R 中 \code{source()}，会得到相同的模型和结果：每个调用都带着
它的种子，LightGBM 的搜索跑固定的次数，而不是固定的时间。

""")


# == build.sh ==================================================================================
patch("docs/manual/build.sh", "figures", r"""# The figures are screenshots of the real window; make them first with
#     QT_QPA_PLATFORM=offscreen python docs/manual/make_figures.py
#     NORMET_UI_LANGUAGE=zh QT_QPA_PLATFORM=offscreen python docs/manual/make_figures.py""",
      r"""# The figures are screenshots of the real window, run on R; make them first (from gui/) with
#     QT_QPA_PLATFORM=offscreen python tools/walk_gui.py
#     NORMET_UI_LANGUAGE=zh QT_QPA_PLATFORM=offscreen python tools/walk_gui.py""")

# The SCM Studio has no Similarity tab: its ranking of donors was Chronos-2's.
patch(EN, "SCM tabs: no Similarity", r"""\tab{All Units}, \tab{Similarity}), and""", r"""\tab{All Units}), and""")
patch(ZH, "SCM tabs: no Similarity", r"""\tab{全部单元}、\tab{相似度}），""", r"""\tab{全部单元}），""")

# == uncertainty decomposition (normet-py PR #58) ==========================================
# The box, the tab and the step as normet-py's book tells them; what differs is the R
# names, this window's backends (h2o where normet-py has flaml), and the quoted numbers,
# which are this window's own run of the figure's settings (walk_gui.py: three members
# sharing 50 draws, lightgbm).

patch(EN, "unc run-buttons row",
      r"""Uncertainty decomposition & an AutoML model & \code{decompose\_uncertainty} \\""",
      r"""Uncertainty decomposition & a model & \code{nm\_decompose\_uncertainty} \\""")
patch(EN, "unc member backend",
      r"""page's budget as its trials) or \code{flaml} (an AutoML search per member, at
that member's budget each).""",
      r"""page's budget as its trials) or \code{h2o} (an H2O AutoML search per member,
at that member's budget each; needs Java and the h2o R package).""")
patch(EN, "unc numbers",
      r"""the median spread is 96\,\% met resampling, 3\,\% the interaction and 0\,\%
model form --- the fitted model is nearly certain about what the weather does,""",
      fill(r"""the median spread is @unc_w@\,\% met resampling, @unc_i@\,\% the interaction and
@unc_m@\,\% model form --- the fitted model is nearly certain about what the weather does,"""))
patch(EN, "unc command log name",
      r"""run is added to the command log as the \code{decompose\_uncertainty} call the
window made""",
      r"""run is added to the command log as the \code{nm\_decompose\_uncertainty} call
the window made""")
patch(EN, "unc R pipeline name",
      r"""\code{do\_all\_unc} run, and no more""",
      r"""\code{nm\_do\_all\_unc} run, and no more""")
patch(EN, "unc caption",
      r"""\screenshot{ui_uncertainty.png}{The attribution of MY1's per-date spread: the
stacked bands (met resampling, model form, the interaction) total 144.3
(\ugm{})$^{2}$ of variance in the median, and the verdict above says where it
goes --- 96\,\% met resampling, 3\,\% interaction, 0\,\% model form (three
members sharing 50 met draws, lightgbm members).""",
      fill(r"""\screenshot{ui_uncertainty.png}{The attribution of MY1's per-date spread: the
stacked bands (met resampling, model form, the interaction) total @unc_total@
(\ugm{})$^{2}$ of variance in the median, and the verdict above says where it
goes --- @unc_w@\,\% met resampling, @unc_i@\,\% interaction, @unc_m@\,\% model
form (three members sharing 50 met draws, lightgbm members)."""))
# The API table's row for nm_decompose_uncertainty is inside the scripting passage's
# rewrite, which covers the whole chapter's function table.

patch(ZH, "unc run-buttons row",
      r"""不确定度分解          & 一个 AutoML 模型 & \code{decompose\_uncertainty} \\""",
      r"""不确定度分解          & 一个模型 & \code{nm\_decompose\_uncertainty} \\""")
patch(ZH, "unc member backend",
      r"""\code{flaml}（每个成员各做一次 AutoML 搜索，各花各自的预算）。""",
      r"""\code{h2o}（每个成员各做一次 H2O AutoML 搜索，各花各自的预算；需要 Java 与 h2o R 包）。""")
patch(ZH, "unc numbers",
      r"""成员、共享 50 次抽样：中位数总离散中 96\,\% 来自气象重采样，交互 3\,\%、模型形式 0\,\%——""",
      fill(r"""成员、共享 50 次抽样：中位数总离散中 @unc_w@\,\% 来自气象重采样，交互 @unc_i@\,\%、模型形式 @unc_m@\,\%——"""))
patch(ZH, "unc command log name",
      r"""\code{decompose\_uncertainty} 调用记入命令日志""",
      r"""\code{nm\_decompose\_uncertainty} 调用记入命令日志""")
patch(ZH, "unc R pipeline name",
      r"""——与一次 \code{do\_all\_unc}""",
      r"""——与一次 \code{nm\_do\_all\_unc}""")
patch(ZH, "unc caption",
      r"""交互）的中位数总方差为 144.3 (\ugm{})$^{2}$，图上方的结论说明它去往何处——96\,\% 气象
重采样、3\,\% 交互、0\,\% 模型形式（共享 50 次抽样的三个成员，lightgbm）。小于该区间的效果，""",
      fill(r"""交互）的中位数总方差为 @unc_total@ (\ugm{})$^{2}$，图上方的结论说明它去往何处——@unc_w@\,\% 气象
重采样、@unc_i@\,\% 交互、@unc_m@\,\% 模型形式（共享 50 次抽样的三个成员，lightgbm）。小于该区间的效果，"""))
# The API table's row, as in the English book, rides in the scripting passage's rewrite.
