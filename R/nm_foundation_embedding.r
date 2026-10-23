# Embedding Diagnostics (multi-site)
#
# Ported from Python normet foundation/embedding_diagnostics.py (PR #64).
# Diagnostics for choosing how to use multi-site embeddings: how separated
# the sites are from one another in the embedding space (the silhouette
# curve), and what the space looks like (a 2-D projection). The module
# deliberately emits no cluster memberships and no recommended k: where a
# clustering is needed as a yardstick (silhouette) it is computed and thrown
# away before the score, so nothing downstream can read a membership off the
# result.

NULL


# Accept the module's input forms and return (n x D) plus row labels.
#
# The natural input is the named list of vectors the embeddings come back as
# ({site: vector}); a bare numeric matrix (or data frame) is also accepted,
# for vectors that come from elsewhere.
#
# @noRd
.nm_embedding_as_matrix <- function(vectors, name = "vectors") {
  if (is.list(vectors) && !is.data.frame(vectors)) {
    if (length(vectors) == 0) {
      stop(sprintf("`%s` needs at least two vectors; got an empty mapping.", name), call. = FALSE)
    }
    dims <- vapply(vectors, function(v) length(as.numeric(v)), integer(1))
    if (length(unique(dims)) != 1) {
      stop(sprintf(
        paste0("`%s`: all vectors must have the same length (got %s)."),
        name, paste(unique(dims), collapse = ", ")
      ), call. = FALSE)
    }
    mat <- do.call(rbind, lapply(vectors, as.numeric))
    vnm <- names(vectors)
    labels <- if (!is.null(vnm) && all(nzchar(vnm))) vnm else as.character(seq_along(vectors))
  } else if (is.matrix(vectors) || is.data.frame(vectors)) {
    mat <- as.matrix(vectors)
    if (!all(vapply(mat, is.numeric, logical(1)))) {
      stop(sprintf(
        paste0(
          "`%s` must be a named list of numeric vectors or a 2-D matrix of ",
          "numeric vectors, got a matrix with non-numeric columns."
        ),
        name
      ), call. = FALSE)
    }
    rn <- rownames(mat)
    labels <- if (!is.null(rn) && !all(rn == as.character(seq_len(nrow(mat))))) {
      rn
    } else {
      as.character(seq_len(nrow(mat)))
    }
  } else {
    stop(sprintf(
      paste0(
        "`%s` must be a named list of vectors (as the embeddings come back) ",
        "or a 2-D matrix of vectors, got %s."
      ),
      name, class(vectors)[1]
    ), call. = FALSE)
  }
  n <- nrow(mat)
  if (n < 2) {
    stop(sprintf("`%s` needs at least two vectors to diagnose; got %d.", name, n), call. = FALSE)
  }
  n_bad <- sum(!is.finite(mat), na.rm = TRUE)
  if (n_bad > 0) {
    stop(sprintf(
      "`%s` carries %d non-finite value(s); clean the vectors first.", name, n_bad
    ), call. = FALSE)
  }
  list(mat = mat, labels = labels)
}


# The cosine dissimilarity, for the metric = "cosine" path. R's dist() has
# no "cosine" method (unlike sklearn's metric names), so it is built here:
# 1 - cosine similarity. A zero vector has no direction; it is treated as
# dissimilar to everything (similarity 0), as sklearn's cosine metric does.
#
# @noRd
.nm_cosine_diss <- function(mat) {
  norms <- sqrt(rowSums(mat^2))
  nz <- norms > 0
  sims <- matrix(0, nrow = nrow(mat), ncol = ncol(mat))
  if (any(nz)) {
    sims[nz, , drop = FALSE] <- mat[nz, , drop = FALSE] %*% t(mat) / outer(norms[nz], norms)
  }
  stats::as.dist(1 - sims)
}


#' The Mean Silhouette as a Function of the Number of Groups
#'
#' The curve answers the question the grouping decision starts from -- how
#' many separated groups of behaviour are there in this embedding space,
#' roughly -- without answering it \emph{for} the user: this function
#' deliberately emits no labels and no recommended k, because that
#' recommendation is the user's to make. KMeans is the yardstick's internal
#' mechanism only: its assignments are discarded before the silhouette is
#' scored, so the result carries no membership information.
#'
#' @param vectors A named list of numeric vectors (the form the embeddings
#'        come back in), or a numeric matrix with one row per site.
#' @param k_range Integer vector of the group counts to score (default
#'        \code{2:11}). A \code{k} that cannot be formed (\code{k < 2} or
#'        \code{k >= n}, or one that collapses to a single cluster) gets a row
#'        with \code{NA} rather than being skipped, so the curve is honest
#'        about what was not scored.
#' @param metric Character. The distance the silhouette is measured in:
#'        \code{"euclidean"} (default) or \code{"cosine"} -- the usual choice
#'        when the vectors have been normalised. (R-side restriction: R's
#'        \code{dist()} covers these two of the sklearn metric names; anything
#'        else is rejected with an error.)
#' @param seed Integer. The seed for the KMeans restarts and the large-input
#'        subsample; the curve is deterministic under it (default 0).
#'
#' @return A data frame with one row per \code{k} in \code{k_range} (sorted,
#'        deduplicated), columns \code{k} and \code{silhouette} (the mean over
#'        the scored points, \code{NA} where \code{k} is infeasible).
#'
#' @note Uses base R only: \code{stats::kmeans} as the yardstick (10 random
#'        restarts, as normet-py's \code{n_init = 10}) and
#'        \code{cluster::silhouette} for the score. For more than 1000 points
#'        the silhouette is scored on a deterministic 1000-point subsample
#'        (normet-py's sklearn \code{sample_size}), which keeps the curve
#'        interactive without changing its reading.
#'
#' @examples
#' set.seed(0)
#' blobs <- c(
#'   lapply(1:10, function(i) rnorm(4, 0, 0.5)),
#'   lapply(1:10, function(i) rnorm(4, 4, 0.5))
#' )
#' names(blobs) <- paste0("site_", seq_along(blobs) - 1)
#' nm_silhouette_curve(blobs, k_range = 2:4)
#'
#' @export
nm_silhouette_curve <- function(vectors, k_range = 2:11, metric = "euclidean", seed = 0) {
  ab <- .nm_embedding_as_matrix(vectors)
  mat <- ab$mat
  n <- nrow(mat)
  metric <- match.arg(metric, choices = c("euclidean", "cosine"))

  rows <- list()
  for (k in sort(unique(as.integer(k_range)))) {
    if (k < 2 || k >= n) {
      rows[[length(rows) + 1L]] <- data.frame(k = k, silhouette = NA_real_)
      next
    }
    # The yardstick's clustering: 10 random restarts, seeded per call as in
    # normet-py (KMeans' random_state), so the curve depends only on the
    # seed, not on the session's RNG state. Warnings (e.g. hitting iter.max)
    # do not change the score.
    km <- tryCatch(
      {
        set.seed(seed)
        suppressWarnings(stats::kmeans(mat, centers = k, nstart = 10))
      },
      error = function(e) NULL
    )
    if (is.null(km) || length(unique(km$cluster)) < 2) {
      # A cluster collapsed (duplicate points): the silhouette is undefined,
      # and the NA row says so.
      rows[[length(rows) + 1L]] <- data.frame(k = k, silhouette = NA_real_)
      next
    }
    # For more than 1000 points, score a deterministic 1000-point subsample,
    # as normet-py does with sklearn's sample_size.
    if (n > 1000L) {
      set.seed(seed)
      idx <- sample.int(n, 1000L)
      score_mat <- mat[idx, , drop = FALSE]
      score_lab <- km$cluster[idx]
    } else {
      score_mat <- mat
      score_lab <- km$cluster
    }
    d <- if (metric == "cosine") .nm_cosine_diss(score_mat) else stats::dist(score_mat)
    s <- cluster::silhouette(score_lab, d)
    rows[[length(rows) + 1L]] <- data.frame(k = k, silhouette = mean(s[, "sil_width"], na.rm = TRUE))
  }
  do.call(rbind, rows)
}


#' Project Multi-Site Embeddings to Two Dimensions
#'
#' Project the vectors onto \code{n_components} dimensions, for the eye.
#'
#' @param vectors As in \code{\link{nm_silhouette_curve}}.
#' @param method Character. \code{"pca"} (default) is pure base R (centre,
#'        then truncated SVD) and adds no dependency. \code{"umap"} has no
#'        backend in the R package and stops with an error naming the Python
#'        package it needs (\code{umap-learn}).
#' @param n_components Integer. The projection's dimension; 2 is what the
#'        diagnostic plot wants.
#' @param seed Integer. Kept for signature parity with normet-py; PCA is
#'        deterministic without it (UMAP, where it is the
#'        \code{random_state}, is not available here). Default 0.
#'
#' @return A numeric matrix of shape (n, n_components), rows in the input's
#'        order.
#'
#' @note PCA component \emph{signs} are not stable across platforms or builds
#'        (the SVD is), so two runs may show mirrored layouts; the geometry --
#'        distances and neighbourhoods -- is the same. The projection is a
#'        view of the vectors, not a statistic to compare numerically.
#'
#' @examples
#' set.seed(0)
#' blobs <- c(
#'   lapply(1:10, function(i) rnorm(4, 0, 0.5)),
#'   lapply(1:10, function(i) rnorm(4, 4, 0.5))
#' )
#' names(blobs) <- paste0("site_", seq_along(blobs) - 1)
#' nm_embedding_projection(blobs)
#'
#' @export
nm_embedding_projection <- function(vectors, method = "pca", n_components = 2, seed = 0) {
  ab <- .nm_embedding_as_matrix(vectors)
  mat <- ab$mat
  if (method == "pca") {
    # sweep, not `mat - colMeans(mat)`: R recycles a bare vector
    # column-major, which would centre each column with a shifted slice of
    # the means instead of its own.
    centred <- sweep(mat, 2, colMeans(mat))
    sv <- svd(centred)
    k <- min(n_components, length(sv$d))
    return(centred %*% sv$v[, seq_len(k), drop = FALSE])
  }
  if (method == "umap") {
    stop(
      paste0(
        "method 'umap' needs the umap-learn package, which the R package has ",
        "no backend for; use method = 'pca'."
      ),
      call. = FALSE
    )
  }
  stop(sprintf("method must be 'pca' or 'umap', got '%s'.", method), call. = FALSE)
}


#' Plot the Two Site-Embedding Diagnostic Panels
#'
#' The two diagnostic panels: the projection, and the silhouette curve.
#'
#' The left panel is the vectors projected by
#' \code{\link{nm_embedding_projection}} -- the sites' positions in the
#' embedding space, at a glance. Coloured by \code{groups} when you supply
#' them (your own grouping, drawn as you chose it), a single colour
#' otherwise: the module itself does not assign any. With 20 or fewer sites
#' each point is annotated with its site name.
#'
#' The right panel is \code{\link{nm_silhouette_curve}}: the mean silhouette
#' against the number of groups. Its peak's position is a reading, not a
#' verdict -- the figure deliberately marks no k.
#'
#' @param vectors As in \code{\link{nm_silhouette_curve}}.
#' @param method, k_range, metric, seed Forwarded to
#'        \code{\link{nm_embedding_projection}} and
#'        \code{\link{nm_silhouette_curve}}.
#' @param groups Character vector, optional. One label per vector, in the
#'        input's order. When given, the scatter is coloured by it; when
#'        absent, every point shares one colour.
#' @param title Character, optional. Figure title; defaults to
#'        \code{"Site embedding diagnostics"}.
#'
#' @return A patchwork figure with the two panels (\code{fig[[1]]} the
#'        scatter, \code{fig[[2]]} the curve). The title actually used is
#'        attached as the \code{title} attribute.
#'
#' @export
nm_plot_embedding_diagnostics <- function(vectors, method = "pca", k_range = 2:11,
                                          metric = "euclidean", seed = 0,
                                          groups = NULL, title = NULL) {
  nm_require("ggplot2")
  nm_require("patchwork", hint = "install.packages('patchwork')")

  ab <- .nm_embedding_as_matrix(vectors)
  mat <- ab$mat
  labels <- ab$labels
  n <- nrow(mat)
  if (!is.null(groups) && length(groups) != n) {
    stop(sprintf("`groups` has %d entries; the input has %d vectors.", length(groups), n),
      call. = FALSE)
  }
  if (!is.null(groups)) groups <- as.character(groups)

  method <- match.arg(method, choices = c("pca", "umap"))
  col <- nm_colours

  pts <- nm_embedding_projection(vectors, method = method, seed = seed)
  pts_df <- data.frame(
    x = pts[, 1],
    y = pts[, 2],
    site = labels,
    group = if (is.null(groups)) rep(NA_character_, n) else groups,
    stringsAsFactors = FALSE
  )

  p1 <- ggplot2::ggplot(pts_df, ggplot2::aes(x = x, y = y))
  if (is.null(groups)) {
    p1 <- p1 + ggplot2::geom_point(colour = col[["observed"]], alpha = 0.8, size = 1.8)
  } else {
    uniq <- sort(unique(groups))
    palette <- c(col[["observed"]], col[["modelled"]], col[["secondary"]],
      col[["tertiary"]], col[["neutral"]], col[["reference"]]
    )
    p1 <- p1 +
      ggplot2::geom_point(ggplot2::aes(colour = factor(group, levels = uniq)), alpha = 0.8, size = 1.8) +
      ggplot2::scale_colour_manual(
        values = unname(palette[seq_along(uniq) %% length(palette) + 1L]),
        labels = uniq
      )
  }
  if (n <= 20) {
    p1 <- p1 + ggplot2::geom_text(ggplot2::aes(label = site), size = 2.2, alpha = 0.8, vjust = -0.5)
  }
  p1 <- p1 +
    ggplot2::labs(
      title = paste0(toupper(method), " projection"),
      x = "component 1", y = "component 2",
      colour = NULL
    ) +
    nm_theme_normet()

  curve <- nm_silhouette_curve(vectors, k_range = k_range, metric = metric, seed = seed)
  p2 <- ggplot2::ggplot(curve, ggplot2::aes(k, silhouette)) +
    ggplot2::geom_line(colour = col[["modelled"]], linewidth = .pt_lw(1.0), na.rm = TRUE) +
    ggplot2::geom_point(colour = col[["modelled"]], size = 1.2) +
    ggplot2::labs(title = "silhouette by k", x = "k (number of groups)", y = "mean silhouette") +
    nm_theme_normet()

  used_title <- title %||% "Site embedding diagnostics"
  fig <- p1 + p2 + patchwork::plot_annotation(title = used_title)
  attr(fig, "title") <- used_title
  fig
}
