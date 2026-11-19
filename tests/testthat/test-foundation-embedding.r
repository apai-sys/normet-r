# Mirrors normet-py's PR #64 tests/test_foundation_embedding_diagnostics.py:
# the embedding diagnostics (silhouette curve, projection, plot). R needs no
# sklearn for the silhouette -- kmeans (stats) and cluster::silhouette are
# base R -- so no test is skipped for a missing backend.

.two_blobs <- function(n_per = 40, dim = 16, seed = 0) {
  # Two well-separated gaussian blobs, keyed by site name like the
  # embeddings come back.
  set.seed(seed)
  a <- 4.0 * rep(1, dim)
  pts <- rbind(
    matrix(rnorm(n_per * dim, 0, 0.5), n_per, dim),
    matrix(rnorm(n_per * dim, 0, 0.5), n_per, dim) + a
  )
  out <- lapply(seq_len(nrow(pts)), function(i) pts[i, ])
  names(out) <- paste0("site_", seq_len(nrow(pts)) - 1)
  out
}

# ---------------------------------------------------------------------------
# nm_silhouette_curve
# ---------------------------------------------------------------------------

test_that("silhouette curve peaks at the true k", {
  curve <- nm_silhouette_curve(.two_blobs(), k_range = 2:8, seed = 0)
  expect_equal(colnames(curve), c("k", "silhouette"))
  expect_equal(curve$k, 2:8)
  finite <- curve[is.finite(curve$silhouette), ]
  # Two clean blobs: the best single cut is k=2, clearly.
  expect_equal(finite$k[which.max(finite$silhouette)], 2)
  expect_gt(max(finite$silhouette), 0.6)
})

test_that("silhouette curve is deterministic under the seed", {
  a <- nm_silhouette_curve(.two_blobs(), k_range = 2:5, seed = 1)
  b <- nm_silhouette_curve(.two_blobs(), k_range = 2:5, seed = 1)
  expect_identical(a, b)
})

test_that("silhouette curve has NaN rows for infeasible k", {
  pts <- .two_blobs(n_per = 3)  # n = 6
  curve <- nm_silhouette_curve(pts, k_range = c(2, 5, 6, 7), seed = 0)
  expect_true(is.finite(curve$silhouette[curve$k == 2]))
  expect_true(is.finite(curve$silhouette[curve$k == 5]))
  # k == n and k > n cannot be formed: NA rows, not dropped rows.
  expect_true(is.na(curve$silhouette[curve$k == 6]))
  expect_true(is.na(curve$silhouette[curve$k == 7]))
})

test_that("silhouette curve accepts bare matrices", {
  blobs <- .two_blobs()
  as_matrix <- do.call(rbind, blobs)
  a <- nm_silhouette_curve(as_matrix, k_range = 2:4, seed = 0)
  b <- nm_silhouette_curve(blobs, k_range = 2:4, seed = 0)
  expect_identical(a, b)
})

test_that("silhouette curve input validation", {
  expect_error(nm_silhouette_curve(list(a = rep(1, 4))), "at least two")
  expect_error(nm_silhouette_curve(list()), "empty mapping")
  expect_error(
    nm_silhouette_curve(list(a = rep(1, 4), b = c(1.0, NA, 1.0, 1.0))),
    "non-finite"
  )
  expect_error(nm_silhouette_curve(c(1.0, 2.0)), "2-D")
})

# ---------------------------------------------------------------------------
# nm_embedding_projection
# ---------------------------------------------------------------------------

test_that("embedding projection: PCA shape and determinism", {
  blobs <- .two_blobs()
  p1 <- nm_embedding_projection(blobs)
  p2 <- nm_embedding_projection(blobs)
  expect_equal(dim(p1), c(80L, 2L))
  expect_equal(p1, p2)
})

test_that("embedding projection: PCA preserves the centre", {
  # A translation of the vectors translates the projection, and the first
  # component lines up with the data's dominant direction.
  blobs <- .two_blobs()
  base <- nm_embedding_projection(blobs)
  shifted <- lapply(blobs, function(v) v + 100.0)
  moved <- nm_embedding_projection(shifted)
  # Centre invariance: the centred projections are identical.
  expect_equal(
    sweep(base, 2, colMeans(base)),
    sweep(moved, 2, colMeans(moved)),
    tolerance = 1e-8
  )
  # The two blobs separate on some component: the between-blob spread
  # exceeds the within-blob spread in the projection.
  half <- nrow(base) %/% 2
  A <- base[seq_len(half), , drop = FALSE]
  B <- base[(half + 1):nrow(base), , drop = FALSE]
  within <- max(sd(sweep(A, 2, colMeans(A))))
  between <- sqrt(sum((colMeans(A) - colMeans(B))^2))
  expect_gt(between, 3.0 * within)
})

test_that("embedding projection: umap has no R backend", {
  # The error must name the Python package the method needs, not be a bare
  # "unknown method".
  expect_error(nm_embedding_projection(.two_blobs(), method = "umap"), "umap-learn")
})

test_that("embedding projection rejects an unknown method", {
  expect_error(nm_embedding_projection(.two_blobs(), method = "tsne"), "'pca' or 'umap'")
})

# ---------------------------------------------------------------------------
# nm_plot_embedding_diagnostics
# ---------------------------------------------------------------------------

test_that("plot smoke: two panels, their titles, the site annotations", {
  fig <- nm_plot_embedding_diagnostics(.two_blobs(n_per = 5))
  expect_s3_class(fig, "patchwork")
  expect_equal(fig[[1]]$labels$title, "PCA projection")
  expect_true(grepl("silhouette by k", fig[[2]]$labels$title, fixed = TRUE))
  # Small input: the sites are annotated by name on the scatter.
  b <- ggplot2::ggplot_build(fig[[1]])
  texts <- unlist(lapply(b$data, function(d) if (!is.null(d$label)) d$label))
  expect_true("site_0" %in% texts)
  expect_true("site_9" %in% texts)
})

test_that("plot with user groups: their labels are coloured, the title is kept", {
  blobs <- .two_blobs(n_per = 4)
  groups <- c(rep("A", 4), rep("B", 4))
  fig <- nm_plot_embedding_diagnostics(blobs, groups = groups, title = "my title")
  expect_equal(attr(fig, "title"), "my title")
  # The user's grouping is what gets coloured: a scale labelled with their
  # labels, in sorted order.
  b <- ggplot2::ggplot_build(fig[[1]])
  sc <- b$plot$scales$get_scales("colour")
  expect_equal(sc$labels, c("A", "B"))
})

test_that("plot: a groups length mismatch is rejected", {
  expect_error(
    nm_plot_embedding_diagnostics(.two_blobs(n_per = 3), groups = c("A", "B")),
    "groups"
  )
})
