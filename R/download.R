download_year <- function(year, output = 'data', extract = TRUE) {
  catalog <- jsonlite::fromJSON('data/archives.json')$archives
  entry <- catalog[catalog$year == year, ]
  if (nrow(entry) != 1L) stop('Year is absent from archive catalog.')
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  target <- file.path(output, entry$filename)
  if (!file.exists(target)) {
    temp <- paste0(target, '.partial')
    options(timeout = max(600, getOption('timeout')))
    if (startsWith(entry$url, 'file://')) {
      source <- URLdecode(sub('^file://', '', entry$url))
      if (.Platform$OS.type == 'windows') source <- sub('^/([A-Za-z]:)', '\\1', source)
      if (!file.copy(source, temp, overwrite = TRUE)) stop('Cannot copy local test archive.')
    } else {
      status <- download.file(entry$url, temp, mode = 'wb', method = 'libcurl', quiet = TRUE)
      if (status != 0L) stop('Download failed.')
    }
    if (!file.rename(temp, target)) stop('Cannot finalize archive download.')
  }
  if (file.info(target)$size != entry$bytes || digest::digest(file = target, algo = 'sha256') != entry$sha256) stop('ZIP checksum/size mismatch: ', target)
  message('Verified ZIP: ', target)
  if (extract) {
    manifest <- jsonlite::fromJSON('data/manifest.json')$files
    expected <- manifest[manifest$year == year, ]
    listing <- unzip(target, list = TRUE)
    if (anyDuplicated(listing$Name) || !setequal(listing$Name, c(expected$path, 'year_manifest.json'))) stop('Unexpected ZIP member list.')
    for (path in expected$path) {
      if (!bundle_path_ok(path)) stop('Unsafe CSV archive path.')
    }
    unzip(target, files = expected$path, exdir = output)
    for (i in seq_len(nrow(expected))) {
      path <- file.path(output, expected$path[i])
      if (file.info(path)$size != expected$bytes[i] || digest::digest(file = path, algo = 'sha256') != expected$sha256[i]) stop('CSV checksum/size mismatch: ', path)
    }
    message('Extracted and verified ', nrow(expected), ' monthly CSV files.')
  }
  invisible(target)
}
