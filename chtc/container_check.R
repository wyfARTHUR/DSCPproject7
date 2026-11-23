packages <- c('data.table', 'arrow', 'stringi', 'digest', 'jsonlite', 'ggplot2')
for (package in packages) {
  if (!requireNamespace(package, quietly = TRUE)) stop('Missing package: ', package)
  cat(package, as.character(packageVersion(package)), '\n')
}
stopifnot(nzchar(Sys.which('python3')))
file <- tempfile(fileext = '.parquet')
arrow::write_parquet(data.frame(x = c(0, 1, 2)), file, compression = 'snappy')
stopifnot(identical(as.numeric(arrow::read_parquet(file)$x), c(0, 1, 2)))
unlink(file)
cat(R.version.string, '\nContainer package and Parquet checks passed\n')
