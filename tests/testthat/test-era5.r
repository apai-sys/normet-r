test_that("coerce_sites parses coordinates input styles cleanly", {
  # 1. Standard data frame format
  df_input <- data.frame(site = "siteA", lat = 45.0, lon = 120.0, stringsAsFactors = FALSE)
  res_df <- normet:::.era5_coerce_sites(df_input)
  expect_equal(res_df$site, "siteA")
  expect_equal(res_df$lat, 45.0)
  expect_equal(res_df$lon, 120.0)

  # 2. Named vector/list style
  list_input <- list("siteB" = c(46.5, 121.5))
  res_list <- normet:::.era5_coerce_sites(list_input)
  expect_equal(res_list$site, "siteB")
  expect_equal(res_list$lat, 46.5)
  expect_equal(res_list$lon, 121.5)

  # 3. Defensive check for malformed columns
  bad_df <- data.frame(site = "siteA", latitude = 45.0, longitude = 120.0)
  expect_error(normet:::.era5_coerce_sites(bad_df))
})
