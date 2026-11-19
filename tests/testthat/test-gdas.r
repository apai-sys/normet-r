test_that(".gdas1_week assigns week boundaries", {
  expect_equal(normet:::.gdas1_week(c(1, 7, 8, 28, 29, 31)), c(1, 1, 2, 4, 5, 5))
})

test_that("nm_gdas1_filenames within a single week", {
  expect_equal(nm_gdas1_filenames("2020-04-05", "2020-04-06"), "gdas1.apr20.w1")
})

test_that("nm_gdas1_filenames spans a week boundary", {
  expect_equal(
    nm_gdas1_filenames("2020-04-07", "2020-04-08"),
    c("gdas1.apr20.w1", "gdas1.apr20.w2")
  )
})

test_that("nm_gdas1_filenames is chronological, de-duplicated, across months", {
  expect_equal(
    nm_gdas1_filenames("2020-04-30", "2020-05-01"),
    c("gdas1.apr20.w5", "gdas1.may20.w1")
  )
})

test_that("nm_gdas1_filenames normalises a reversed range", {
  expect_equal(nm_gdas1_filenames("2020-01-31", "2020-01-29"), "gdas1.jan20.w5")
})
