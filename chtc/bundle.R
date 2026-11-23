# R-native transfer bundles contain regular files as raw bytes, never links.
bundle_is_link <- function(path) {
  link <- Sys.readlink(path)
  !is.na(link) & nzchar(link)
}
bundle_path_ok <- function(path) {
  path <- gsub('\\\\', '/', path)
  nzchar(path) && !grepl('^(/|~|[A-Za-z]:)', path) &&
    !any(strsplit(path, '/', fixed = TRUE)[[1]] %in% c('..', ''))
}

bundle_inside <- function(path, root) {
  path <- normalizePath(path, winslash = '/', mustWork = FALSE)
  root <- normalizePath(root, winslash = '/', mustWork = TRUE)
  startsWith(paste0(path, '/'), paste0(root, '/')) && path != root
}

pack_bundle <- function(target, root, paths) {
  root <- normalizePath(root, winslash = '/', mustWork = TRUE)
  files <- unique(unlist(lapply(paths, function(relative) {
    if (!bundle_path_ok(relative)) stop('Unsafe bundle path: ', relative)
    path <- file.path(root, relative)
    if (dir.exists(path)) file.path(relative, list.files(path, recursive = TRUE, all.files = TRUE, no.. = TRUE))
    else if (file.exists(path)) relative else character()
  }), use.names = FALSE))
  entries <- setNames(lapply(files, function(relative) {
    path <- file.path(root, relative)
    if (!bundle_inside(path, root) || bundle_is_link(path)) stop('Unsafe output path: ', path)
    size <- file.info(path)$size
    if (size > .Machine$integer.max) stop('Transfer member exceeds 2 GiB: ', relative)
    bytes <- readBin(path, 'raw', n = size)
    list(bytes = bytes, sha256 = digest::digest(bytes, algo = 'sha256', serialize = FALSE))
  }), gsub('\\\\', '/', files))
  dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
  temp <- paste0(target, '.partial')
  saveRDS(list(version = 1L, files = entries), temp, compress = 'gzip')
  if (file.exists(target)) unlink(target)
  if (!file.rename(temp, target)) stop('Cannot finalize transfer bundle.')
  invisible(target)
}

unpack_bundle <- function(path, destination, only = NULL) {
  value <- readRDS(path)
  if (!identical(value$version, 1L) || !is.list(value$files) || anyDuplicated(names(value$files))) stop('Invalid transfer bundle.')
  dir.create(destination, recursive = TRUE, showWarnings = FALSE)
  destination <- normalizePath(destination, winslash = '/', mustWork = TRUE)
  for (relative in names(value$files)) {
    if (!bundle_path_ok(relative)) stop('Unsafe archive path: ', relative)
    if (!is.null(only) && !relative %in% only) next
    item <- value$files[[relative]]
    if (!is.raw(item$bytes) || digest::digest(item$bytes, algo = 'sha256', serialize = FALSE) != item$sha256) stop('Transfer checksum mismatch: ', relative)
    target <- file.path(destination, relative)
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    if (!bundle_inside(dirname(target), destination) && normalizePath(dirname(target), winslash = '/') != destination) stop('Escaped destination.')
    if (bundle_is_link(target)) stop('Refusing to write through a symbolic link.')
    writeBin(item$bytes, target)
  }
  invisible(value)
}

copy_outputs <- function(root, destination, paths) {
  temp <- tempfile(fileext = '.rds')
  on.exit(unlink(temp), add = TRUE)
  pack_bundle(temp, root, paths)
  unpack_bundle(temp, destination)
}
