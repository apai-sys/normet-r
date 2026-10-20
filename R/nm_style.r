# A figure style of the kind journals ask for, shared by every figure normet draws.
#
# What it sets is what Nature Portfolio's, Science's, ACP's and ES&T's guides for
# figures have in common: a sans-serif face, 7 to 8.5 pt text, 0.6 pt axes with ticks
# outward, legends without a frame, colours a colour-blind reader can tell apart (Okabe
# and Ito's), and one meaning per colour in every figure: what was measured in blue,
# what a model makes of it in red, context in grey.
#
#   nm_theme_normet()    the ggplot2 theme
#   nm_palette           the categorical colours; nm_colours the colours with a meaning
#   nm_formula(text)     NO2, PM2.5, SO42- written as chemistry writes them
#   .break_at_gaps()     a row of NA put in each gap, so a line stops there
#   .series_width()      a line as wide as its series is dense

NULL

#' Colours normet's figures draw in
#'
#' `nm_palette` is Okabe and Ito's colour-blind-safe eight (less black), then five of
#' Paul Tol's muted, for categories (sources, variables, sites), one each.
#' `nm_colours` gives what a colour stands for, the same in every figure: `observed`
#' (a measured series), `modelled` (the normalised series, a synthetic control, a fit),
#' `component` (one part of a decomposition), `secondary` and `tertiary` (a third and a
#' fourth series), `neutral` (noise, the donors, what is context rather than result),
#' `ink` (text, and a line that is no series': a 1:1 line, a cutoff) and `reference` (a
#' zero line).
#'
#' @format A character vector of hex colours (`nm_colours` is named).
#' @seealso \code{\link{nm_theme_normet}}
#' @export
nm_palette <- c(
  "#0072B2", # blue
  "#D55E00", # vermilion
  "#009E73", # bluish green
  "#E69F00", # orange
  "#56B4E9", # sky blue
  "#CC79A7", # reddish purple
  "#F0E442", # yellow
  "#332288", # indigo
  "#882255", # wine
  "#44AA99", # teal
  "#999933", # olive
  "#AA4499"  # magenta
)

#' @rdname nm_palette
#' @export
nm_colours <- c(
  observed = "#007AFF",
  modelled = "#FF3B30",
  component = "#007AFF",
  secondary = "#34C759",
  tertiary = "#FF9500",
  neutral = "#8E8E93",
  ink = "#1A1A1A",
  reference = "#8E8E93"
)

.GRID_COLOUR <- "#E5E5EA"

# Points to ggplot2's linewidth unit (mm).
.pt_lw <- function(pt) pt / 2.845276

#' The journal figure style as a ggplot2 theme
#'
#' 7 pt tick labels, 8 pt axis titles and an 8.5 pt left-aligned title, 0.6 pt axes
#' boxed round the panel with ticks outward, a faint grid under the data, legends
#' without a frame or keys' background, and facet titles without a strip. Every
#' plotting function in normet draws in it; add it to your own figures to match.
#'
#' @param base_size Base font size in points. Default 8.
#' @param base_family Font family. Default `""` (the device's sans-serif).
#' @param grid Logical. Draw the faint major grid. Default `TRUE`.
#' @return A ggplot2 theme.
#' @examples
#' library(ggplot2)
#' ggplot(my1[1:200, ], aes(date, NO2)) +
#'   geom_line(colour = nm_colours[["observed"]]) +
#'   nm_theme_normet()
#' @export
nm_theme_normet <- function(base_size = 8, base_family = "", grid = TRUE) {
  nm_require("ggplot2")
  el <- ggplot2::element_text
  ink <- nm_colours[["ink"]]
  rel <- function(pt) pt / 8 * base_size
  ggplot2::theme_bw(base_size = base_size, base_family = base_family) +
    ggplot2::theme(
      text = el(colour = ink),
      plot.title = el(size = rel(8.5), hjust = 0, colour = ink,
                      margin = ggplot2::margin(b = 4)),
      plot.title.position = "plot",
      plot.subtitle = el(size = rel(7.5), hjust = 0),
      axis.title = el(size = rel(8), colour = ink),
      axis.text = el(size = rel(7), colour = "#333333"),
      axis.ticks = ggplot2::element_line(colour = "#333333", linewidth = .pt_lw(0.6)),
      axis.ticks.length = ggplot2::unit(3, "pt"),
      panel.border = ggplot2::element_rect(fill = NA, colour = "#262626",
                                           linewidth = .pt_lw(0.6)),
      panel.grid.major = if (grid) {
        ggplot2::element_line(colour = .GRID_COLOUR, linewidth = .pt_lw(0.5))
      } else {
        ggplot2::element_blank()
      },
      panel.grid.minor = ggplot2::element_blank(),
      legend.background = ggplot2::element_blank(),
      legend.key = ggplot2::element_blank(),
      legend.text = el(size = rel(7)),
      legend.title = el(size = rel(7)),
      legend.key.height = ggplot2::unit(9, "pt"),
      legend.key.width = ggplot2::unit(14, "pt"),
      strip.background = ggplot2::element_blank(),
      strip.text = el(size = rel(7.5), hjust = 0, colour = ink,
                      margin = ggplot2::margin(b = 2)),
      plot.background = ggplot2::element_rect(fill = "white", colour = NA)
    )
}

# -- formulas -------------------------------------------------------------------------

.ELEMENTS <- strsplit(paste(
  "H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As",
  "Se Br Kr Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd",
  "Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu"
), " ")[[1]]
# Names that read as formulas and are not: the thermal fractions of organic and
# elemental carbon (OC1-OC4, EC1-EC3), pyrolysed carbon (OP) and S2, whose digits count
# no atoms.
.NOT_A_FORMULA <- "^(?:(?:OC|EC|OP)\\d?|S2)$"
.MINUS_SIGN <- intToUtf8(0x2212)
.PM_RE <- "(?<![\\w.$\\\\])PM(\\d+(?:\\.\\d+)?)(?![\\w$])"
.FORMULA_RE <- paste0("(?<![\\w.$\\\\])((?:[A-Z][a-z]?\\d*)+)(\\^?\\d*[+\\-", .MINUS_SIGN,
                      "])?(?![\\w$])")

# Unicode sub- and superscripts for digits and signs.
.script <- function(text, sup = FALSE) {
  chars <- strsplit(text, "")[[1]]
  map_sub <- c(`0` = 0x2080, `1` = 0x2081, `2` = 0x2082, `3` = 0x2083, `4` = 0x2084,
               `5` = 0x2085, `6` = 0x2086, `7` = 0x2087, `8` = 0x2088, `9` = 0x2089,
               `+` = 0x208A, `-` = 0x208B)
  map_sup <- c(`0` = 0x2070, `1` = 0xB9, `2` = 0xB2, `3` = 0xB3, `4` = 0x2074,
               `5` = 0x2075, `6` = 0x2076, `7` = 0x2077, `8` = 0x2078, `9` = 0x2079,
               `+` = 0x207A, `-` = 0x207B)
  map <- if (sup) map_sup else map_sub
  paste(vapply(chars, function(ch) {
    if (ch %in% names(map)) intToUtf8(map[[ch]]) else ch
  }, character(1)), collapse = "")
}

# One formula match, as a list of (symbol, count) parts and a charge, or NULL when it
# only reads as one.
.formula_parts <- function(match) {
  m <- regmatches(match, regexec(
    paste0("^((?:[A-Z][a-z]?\\d*)+)(\\^?\\d*[+\\-", .MINUS_SIGN, "])?$"), match, perl = TRUE
  ))[[1]]
  if (!length(m)) return(NULL)
  body <- m[2]
  charge <- m[3]
  if (grepl(.NOT_A_FORMULA, body, perl = TRUE)) return(NULL)
  p <- regmatches(body, gregexpr("[A-Z][a-z]?\\d*", body))[[1]]
  syms <- sub("\\d+$", "", p)
  counts <- sub("^[A-Z][a-z]?", "", p)
  if (!length(syms) || any(!syms %in% .ELEMENTS)) return(NULL)
  charge <- gsub(.MINUS_SIGN, "-", sub("^\\^", "", charge), fixed = TRUE)
  if (nzchar(charge) && nchar(charge) == 1) {
    # A charge's size written before its sign: Ca2+ is calcium's ion, one atom;
    # SO42- is sulfate's, the count's last digit its charge.
    k <- length(syms)
    if (k == 1 && nzchar(counts[k])) {
      charge <- paste0(counts[k], charge)
      counts[k] <- ""
    } else if (nchar(counts[k]) > 1) {
      n <- nchar(counts[k])
      charge <- paste0(substr(counts[k], n, n), charge)
      counts[k] <- substr(counts[k], 1, n - 1)
    }
  }
  if (!nzchar(charge) && !any(nzchar(counts) & counts != "1")) {
    return(NULL) # nothing to set lower or higher: CO, NO, Na
  }
  list(syms = syms, counts = counts, charge = charge)
}

# Replace each match of `pattern` in `text` (one string) with fn(match).
.sub_each <- function(text, pattern, fn) {
  m <- gregexpr(pattern, text, perl = TRUE)
  if (m[[1]][1] == -1) return(text)
  hits <- regmatches(text, m)[[1]]
  regmatches(text, m) <- list(vapply(hits, fn, character(1), USE.NAMES = FALSE))
  text
}

.formula_unicode <- function(text) {
  text <- .sub_each(text, .PM_RE, function(h) paste0("PM", .script(sub("^PM", "", h))))
  .sub_each(text, .FORMULA_RE, function(h) {
    f <- .formula_parts(h)
    if (is.null(f)) return(h)
    out <- paste0(f$syms, vapply(f$counts, .script, character(1)), collapse = "")
    if (nzchar(f$charge)) out <- paste0(out, .script(f$charge, sup = TRUE))
    out
  })
}

# A plotmath string for `text`: plain runs quoted, formulas set as NO[2], SO[4]^"2-".
.formula_plotmath <- function(text) {
  pieces <- character(0)
  rest <- text
  quote_txt <- function(s) paste0('"', gsub('(["\\\\])', "\\\\\\1", s), '"')
  repeat {
    pm <- regexpr(.PM_RE, rest, perl = TRUE)
    fm <- regexpr(.FORMULA_RE, rest, perl = TRUE)
    hits <- c(pm = pm, fm = fm)
    found <- hits[hits > 0]
    if (!length(found)) break
    which_hit <- names(found)[which.min(found)]
    at <- found[[which_hit]]
    len <- attr(if (which_hit == "pm") pm else fm, "match.length")
    token <- substr(rest, at, at + len - 1)
    expr <- if (which_hit == "pm") {
      sprintf('PM[%s]', quote_txt(sub("^PM", "", token)))
    } else {
      f <- .formula_parts(token)
      if (is.null(f)) NULL else {
        parts <- ifelse(nzchar(f$counts), sprintf("%s[%s]", f$syms, f$counts), f$syms)
        k <- length(parts)
        if (nzchar(f$charge)) parts[k] <- sprintf("%s^%s", parts[k], quote_txt(f$charge))
        paste(parts, collapse = "*")
      }
    }
    before <- substr(rest, 1, at - 1)
    if (is.null(expr)) {
      pieces <- c(pieces, quote_txt(paste0(before, token)))
    } else {
      if (nzchar(before)) pieces <- c(pieces, quote_txt(before))
      pieces <- c(pieces, expr)
    }
    rest <- substr(rest, at + len, nchar(rest))
  }
  if (nzchar(rest)) pieces <- c(pieces, quote_txt(rest))
  if (length(pieces) == 1) return(pieces) else paste0("paste(", paste(pieces, collapse = ", "), ")")
}

#' Write chemical formulas as chemistry writes them
#'
#' Each chemical formula in `text` with its counts below and its charge above: NO2,
#' SO2, O3, PM2.5, PM10, NH4+, SO42-. What only reads as one is left: CO and NO
#' (nothing to set lower), OC1 and EC2 (thermal fractions), and any name that is not all
#' elements (`ws`, `blh`, `atmos_pres`).
#'
#' @param text Character vector.
#' @param as `"unicode"` (default) for text with Unicode sub- and superscripts
#'   (NO\eqn{_2}), which every device with a Unicode font draws (png, ragg, cairo);
#'   `"plotmath"` for a plotmath expression, which every device draws, the PDF device
#'   included. A text with nothing to set comes back as it was, as text.
#' @return A character vector, or (for `as = "plotmath"`, where something was set) an
#'   expression.
#' @examples
#' nm_formula(c("NO2", "PM2.5", "SO42-", "NH4+", "CO", "ws"))
#' nm_formula("Time series of NO2", as = "plotmath")
#' @export
nm_formula <- function(text, as = c("unicode", "plotmath")) {
  as <- match.arg(as)
  if (is.null(text)) return(text)
  text <- as.character(text)
  if (as == "unicode") {
    return(vapply(text, function(t) if (is.na(t)) t else .formula_unicode(t), character(1),
                  USE.NAMES = FALSE))
  }
  strs <- vapply(text, function(t) if (is.na(t)) NA_character_ else .formula_plotmath(t),
                 character(1), USE.NAMES = FALSE)
  plain <- vapply(seq_along(text), function(i) {
    is.na(strs[i]) || identical(strs[i], paste0('"', gsub('(["\\\\])', "\\\\\\1", text[i]), '"'))
  }, logical(1))
  if (all(plain)) return(text)
  parse(text = ifelse(is.na(strs), '""', strs), keep.source = FALSE)
}

# A label for a figure: formulas set in plotmath (drawn on every device).
.fl <- function(text) {
  if (is.null(text) || !is.character(text) || length(text) != 1) return(text)
  out <- nm_formula(text, as = "plotmath")
  if (is.expression(out)) out[[1]] else out
}

# -- series ---------------------------------------------------------------------------

# An interval this many times a record's median spacing is a gap in it, where a series is
# drawn broken rather than joined across: an hourly record's missing days are, a
# day-to-day wobble in a sampler's schedule is not.
.GAP_SPACINGS <- 5

# `df` with a row of NA (in `cols`) put in every gap in `x_col` -- an interval over
# .GAP_SPACINGS times the median -- so a line or a band stops there. Unchanged where
# there is no gap, or where x is not ordered.
.break_at_gaps <- function(df, x_col, cols) {
  n <- nrow(df)
  if (n < 3) return(df)
  t <- as.numeric(df[[x_col]])
  step <- diff(t)
  if (anyNA(step) || any(step < 0) || !any(step > 0)) return(df)
  gaps <- which(step > .GAP_SPACINGS * stats::median(step[step > 0]))
  if (!length(gaps)) return(df)
  filler <- df[gaps, , drop = FALSE]
  mid <- (t[gaps] + t[gaps + 1]) / 2
  x <- df[[x_col]]
  filler[[x_col]] <- if (inherits(x, "POSIXct")) {
    .POSIXct(mid, tz = attr(x, "tzone") %||% "UTC")
  } else if (inherits(x, "Date")) {
    as.Date(mid, origin = "1970-01-01")
  } else {
    mid
  }
  for (c in intersect(cols, names(filler))) filler[[c]] <- NA
  out <- rbind(df, filler)
  out[order(as.numeric(out[[x_col]])), , drop = FALSE]
}

# A line's width (ggplot2 units) for a series of n points: hairlines for months of
# hours, fuller for a short or averaged series; the series a figure is about a step wider.
.series_width <- function(n, emphasis = FALSE) {
  base <- if (n > 1500) 0.5 else if (n > 300) 0.9 else 1.2
  .pt_lw(base + if (emphasis) 0.3 else 0)
}

# A time axis written as briefly as each tick's level needs (the year once).
.time_scale <- function(x) {
  if (inherits(x, "POSIXct")) {
    ggplot2::scale_x_datetime(labels = scales::label_date_short(), expand = c(0, 0))
  } else if (inherits(x, "Date")) {
    ggplot2::scale_x_date(labels = scales::label_date_short(), expand = c(0, 0))
  } else {
    ggplot2::scale_x_continuous(expand = c(0, 0))
  }
}

# A dotted vertical line at an intervention's date, and a thin line at y = 0.
.cutoff_line <- function(at) {
  ggplot2::geom_vline(xintercept = at, colour = nm_colours[["ink"]], linetype = "22",
                      linewidth = .pt_lw(0.7))
}
.zero_line <- function() {
  ggplot2::geom_hline(yintercept = 0, colour = nm_colours[["reference"]],
                      linewidth = .pt_lw(0.6))
}

# The x column as times: POSIXct kept (a sub-daily record keeps its hours), Date kept,
# text parsed.
.as_time <- function(x) {
  if (inherits(x, c("POSIXct", "Date"))) return(x)
  .to_datetime_coerced(x)
}

# A cutoff on the x column's own scale.
.as_cutoff <- function(cutoff, x) {
  if (inherits(x, "Date")) as.Date(cutoff) else .to_datetime_coerced(as.character(cutoff))
}

# -- language -------------------------------------------------------------------------

.nm_i18n_cache <- new.env(parent = emptyenv())

.nm_catalogue <- function(lang) {
  if (identical(lang, "en")) return(NULL)
  if (is.null(.nm_i18n_cache[[lang]])) {
    path <- system.file("i18n", paste0(lang, ".json"), package = "normet")
    .nm_i18n_cache[[lang]] <- if (nzchar(path)) {
      jsonlite::fromJSON(path, simplifyVector = FALSE)
    } else {
      list()
    }
  }
  .nm_i18n_cache[[lang]]
}

# One of normet's own texts in `lang` (default: the "normet.lang" option, "en"), its
# {s0}, {s1}, ... filled from `...`. A text with no translation stays English.
.say <- function(text, ..., lang = getOption("normet.lang", "en"), part = "texts") {
  values <- list(...)
  cat <- .nm_catalogue(lang)
  if (!is.null(cat) && !is.null(cat[[part]][[text]])) {
    text <- cat[[part]][[text]]
    Encoding(text) <- "UTF-8"
  }
  for (i in seq_along(values)) {
    text <- gsub(sprintf("{s%d}", i - 1L), as.character(values[[i]]), text, fixed = TRUE)
  }
  text
}
