test_that("whether H2O is up is FALSE, not an error, before any cluster is started", {
  skip_if_not_installed("h2o")
  # h2o.clusterIsUp() stops with "No active connection" in a session that has none.
  skip_if(isTRUE(tryCatch(h2o::h2o.clusterIsUp(), error = function(e) FALSE)),
          "an H2O cluster is connected in this session")
  expect_error(h2o::h2o.clusterIsUp(), "No active connection")
  expect_false(.nm_h2o_up())
})
