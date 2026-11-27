options(stringsAsFactors = FALSE)
project_lib <- Sys.getenv('DSCP_R_LIB', '.Rlib')
if (dir.exists(project_lib)) .libPaths(c(project_lib, .libPaths()))

need_packages <- function(packages) {
  missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) stop('Missing R packages: ', paste(missing, collapse = ', '),
                            '. Run Rscript scripts/install_packages.R first.')
}

parse_args <- function(args = commandArgs(trailingOnly = TRUE)) {
  out <- list()
  while (length(args)) {
    if (!startsWith(args[1], '--') || length(args) < 2L) stop('Use --name value arguments.')
    key <- substring(args[1], 3L)
    if (!is.null(out[[key]])) stop('Duplicate argument: ', key)
    out[[key]] <- args[2]
    args <- args[-c(1L, 2L)]
  }
  out
}

month_number <- function(x) {
  if (anyNA(x) || any(!grepl('^[0-9]{4}-(0[1-9]|1[0-2])$', x))) stop('Invalid YYYY-MM month.')
  as.integer(substr(x, 1L, 4L)) * 12L + as.integer(substr(x, 6L, 7L)) - 1L
}

month_label <- function(x) sprintf('%04d-%02d', as.integer(x) %/% 12L, as.integer(x) %% 12L + 1L)

atomic_file <- function(path, writer) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- tempfile(pattern = '.writing-', tmpdir = dirname(path))
  on.exit(unlink(tmp), add = TRUE)
  writer(tmp)
  if (dir.exists(path)) stop('Expected a file, found a directory: ', path)
  if (file.exists(path)) unlink(path)
  if (!file.rename(tmp, path)) stop('Cannot finalize output: ', path)
  invisible(path)
}

write_pq <- function(x, path) atomic_file(path, function(tmp) arrow::write_parquet(as.data.frame(x), tmp, compression = 'snappy'))
read_pq <- function(path, columns = NULL) {
  value <- if (is.null(columns)) arrow::read_parquet(path) else arrow::read_parquet(path, col_select = tidyselect::all_of(columns))
  data.table::as.data.table(value)
}
write_tsv <- function(x, path) atomic_file(path, function(tmp) data.table::fwrite(x, tmp, sep = '\t', na = '', quote = 'auto'))
write_json <- function(x, path) atomic_file(path, function(tmp) jsonlite::write_json(x, tmp, pretty = TRUE, auto_unbox = TRUE, na = 'null'))
write_rds <- function(x, path) atomic_file(path, function(tmp) saveRDS(x, tmp))
sha <- function(x) digest::digest(x, algo = 'sha256', serialize = TRUE)

init_context <- function(args = parse_args()) {
  need_packages(c('data.table', 'arrow', 'stringi', 'digest', 'jsonlite'))
  suppressPackageStartupMessages(library(data.table))
  nthreads <- suppressWarnings(as.integer(Sys.getenv('DSCP_CPUS', '2')))
  if (is.na(nthreads) || nthreads < 1L) nthreads <- 2L
  data.table::setDTthreads(nthreads)
  arrow::set_cpu_count(nthreads)
  cfg_path <- if (is.null(args$config)) 'config/analysis.json' else args$config
  cfg <- if (grepl('\\.json$', cfg_path, ignore.case = TRUE)) jsonlite::fromJSON(cfg_path) else dget(cfg_path)
  if (!is.list(cfg)) stop('Config must evaluate to a list.')
  if (!is.null(args$input)) cfg$input_dir <- args$input
  if (!is.null(args$manifest)) cfg$input_manifest <- args$manifest
  if (month_number(cfg$start_month) > month_number(cfg$end_month)) stop('Invalid date range.')
  if (cfg$n_shards < 1L || cfg$n_shards != as.integer(cfg$n_shards)) stop('n_shards must be a positive integer.')
  if (cfg$min_post_peak_months < 12L) stop('The proposal requires at least 12 post-peak observed months.')
  if (!is.finite(cfg$max_abs_rate) || cfg$max_abs_rate <= 0) stop('Invalid rate bound.')
  if (cfg$rate_zero_tolerance <= 0 || cfg$rate_zero_tolerance >= cfg$max_abs_rate) stop('Invalid zero-rate tolerance.')
  if (month_number(cfg$pandemic_start) > month_number(cfg$pandemic_end)) stop('Invalid pandemic sensitivity range.')
  fmap <- data.table::fread(cfg$format_map, colClasses = 'character')
  if (!identical(names(fmap), c('materialtype', 'usageclass', 'format'))) stop('Invalid format_map schema.')
  if (anyDuplicated(fmap[, .(materialtype, usageclass)]) || any(!fmap$format %in% c('print', 'ebook', 'digital_audio'))) stop('Invalid format map.')
  if (anyNA(fmap) || any(fmap == '')) stop('Blank entries in format map.')
  out <- if (is.null(args$out)) 'analysis_output' else args$out
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  code <- sort(c(list.files('R', pattern = '\\.R$', full.names = TRUE),
                 list.files('scripts', pattern = '^0[1-4]_.*\\.R$', full.names = TRUE)))
  code_sha <- vapply(code, function(p) digest::digest(file = p, algo = 'sha256'), character(1))
  signature <- sha(list(version = 1L, config = cfg, format_map = as.data.frame(fmap), code = code_sha))
  list(cfg = cfg, args = args, out = out, fmap = fmap, signature = signature,
       years = seq.int(as.integer(substr(cfg$start_month, 1, 4)), as.integer(substr(cfg$end_month, 1, 4))),
       started = proc.time()[['elapsed']])
}

require_marker <- function(path, signature) {
  if (!file.exists(path)) stop('Missing successful prerequisite: ', path)
  value <- readRDS(path)
  if (!identical(value$signature, signature)) stop('Stale/incompatible prerequisite: ', path, '. Use a new run directory or rerun prerequisites.')
  value
}

finish_stage <- function(ctx, stage, extra = list()) {
  metric <- c(list(stage = stage, elapsed_seconds = proc.time()[['elapsed']] - ctx$started,
                  max_r_heap_mb = sum(gc()[, 6L]), job_id = Sys.getenv('DSCP_JOB_ID'),
                  task_id = Sys.getenv('DSCP_TASK_ID'),
                  R_version = R.version.string, signature = ctx$signature), extra)
  write_json(metric, file.path(ctx$out, 'metrics', paste0(stage, '.json')))
  capture.output(sessionInfo(), file = file.path(ctx$out, 'metrics', paste0(stage, '-session.txt')))
  message('COMPLETED ', stage)
}

normalize_text <- function(x) {
  x <- stringi::stri_trans_nfkc(x)
  x <- stringi::stri_trans_casefold(x)
  x <- stringi::stri_replace_all_regex(x, '[\\p{P}\\p{Z}\\s\\p{Cc}]+', ' ')
  stringi::stri_trim_both(x)
}

normalize_title <- function(x) {
  x <- stringi::stri_trans_casefold(stringi::stri_trans_nfkc(x))
  x <- stringi::stri_replace_first_regex(x, '\\s+/\\s*.*$', '')
  x <- stringi::stri_replace_all_regex(x, '\\[(electronic resource|electronic audio resource|sound recording|large print)\\]', ' ')
  x <- stringi::stri_replace_first_regex(x, '(?:\\s*\\(unabridged\\))+\\s*$', '')
  normalize_text(x)
}

normalize_creator <- function(x) {
  x <- stringi::stri_trans_nfkc(x)
  x <- stringi::stri_replace_first_regex(x, ',\\s*[0-9]{4}(?:-[0-9]{0,4})?\\.?\\s*$', '')
  x <- stringi::stri_replace_first_regex(x, '^([^,]+),\\s*([^,]+)$', '$2 $1')
  normalize_text(x)
}

# SPL only records a title in months with at least one checkout, so an absent
# work-format-month after the series first appears is a true zero. Months without
# a positive format denominator (configured exclusions, zero-total months) stay absent.
complete_zero_months <- function(d, totals) {
  observed <- d[, .(work_id, format, month_index, checkouts, observed_total = format_total)]
  if (!nrow(observed)) return(d[0, .(work_id, format, period, month_index, checkouts, format_total)])
  if (anyDuplicated(observed[, .(work_id, format, month_index)])) stop('Duplicate work-format-month rows before zero filling.')
  first <- observed[, .(first_month = min(month_index)), by = .(work_id, format)]
  months <- totals[format_total > 0, .(format, period, month_index, format_total)]
  if (anyDuplicated(months[, .(format, month_index)])) stop('Duplicate format-month denominators.')
  grid <- merge(first, months, by = 'format', allow.cartesian = TRUE)[month_index >= first_month]
  full <- merge(grid, observed, by = c('work_id', 'format', 'month_index'), all.x = TRUE)
  if (nrow(observed[!full, on = .(work_id, format, month_index)])) stop('Observed rows lack a positive format-month denominator.')
  if (any(!is.na(full$observed_total) & full$observed_total != full$format_total)) stop('Shard denominator disagrees with format-month totals.')
  full[is.na(checkouts), checkouts := 0]
  data.table::setorder(full, work_id, format, month_index)
  full[, .(work_id, format, period, month_index, checkouts, format_total)]
}

work_key <- function(title, creator) paste(title, creator, sep = '\037')
work_ids <- function(keys) paste0('w_', vapply(keys, digest::digest, character(1), algo = 'sha256', serialize = FALSE, USE.NAMES = FALSE))
short_examples <- function(x, n = 3L) paste(head(sort(unique(x[!is.na(x) & nzchar(x)])), n), collapse = ' || ')

merge_state <- function(ctx) {
  state <- require_marker(file.path(ctx$out, 'merge_success.rds'), ctx$signature)
  current <- read_overrides(ctx)
  if (!identical(state$override_signature, sha(as.data.frame(current)))) stop('Match overrides changed. Rerun 02_build_shards.R.')
  state
}

read_overrides <- function(ctx) {
  x <- data.table::fread(ctx$cfg$match_overrides, colClasses = 'character', na.strings = '')
  if (!identical(names(x), c('title_norm', 'creator_norm', 'work_id', 'include', 'notes'))) stop('Invalid match_overrides schema.')
  if (anyDuplicated(x[, .(title_norm, creator_norm)])) stop('Duplicate normalized key in overrides.')
  if (nrow(x)) {
    if (anyNA(x$title_norm) || anyNA(x$creator_norm) || anyNA(x$include) || any(!x$include %in% c('TRUE', 'FALSE'))) stop('Overrides require normalized title, creator and TRUE/FALSE include.')
    if (any(!is.na(x$work_id) & !grepl('^[A-Za-z0-9._-]+$', x$work_id))) stop('Invalid override work_id.')
  }
  x
}

matching_method <- function() 'normalized_title_creator_with_optional_overrides'
