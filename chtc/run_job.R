#!/usr/bin/env Rscript
script <- sub('^--file=', '', grep('^--file=', commandArgs(FALSE), value = TRUE)[1])
project <- normalizePath(file.path(dirname(script), '..'), winslash = '/', mustWork = TRUE)
sandbox <- normalizePath(Sys.getenv('DSCP_JOB_SANDBOX', '/invalid-sandbox'), winslash = '/', mustWork = FALSE)
if (project != sandbox || dir.exists(file.path(project, '.git'))) stop('Run only in the disposable job sandbox, never in your Git checkout.')
transfer <- normalizePath(Sys.getenv('DSCP_TRANSFER_DIR'), winslash = '/', mustWork = TRUE)
if (transfer == project || startsWith(transfer, paste0(project, '/'))) stop('Transfer directory must be outside the sandbox.')
setwd(project)
source('R/common.R')
source('chtc/bundle.R')
source('R/download.R')
need_packages(c('jsonlite', 'digest'))
args <- commandArgs(TRUE)
if (length(args) != 3L || !args[1] %in% c('year', 'merge', 'audit', 'fit', 'compare') || !args[3] %in% c('true', 'false')) stop('Use stage item true|false.')
stage <- args[1]; item <- as.integer(args[2]); allow <- args[3]
Sys.setenv(DSCP_TASK_ID = args[2])
cfg <- jsonlite::fromJSON('config/analysis.json')
years <- seq.int(as.integer(substr(cfg$start_month, 1, 4)), as.integer(substr(cfg$end_month, 1, 4)))
stage_id <- paste0(stage, if (item != 0L) paste0('-', item) else '')
status_path <- paste0('run/job_status/', stage_id, '.json')
dir.create(dirname(status_path), recursive = TRUE, showWarnings = FALSE)
started <- proc.time()[['elapsed']]
success <- FALSE; error <- ''; outputs <- list()
R <- function(script, extra = character()) {
  command <- Sys.getenv('RSCRIPT', file.path(R.home('bin'), 'Rscript'))
  args <- c('--vanilla', script, '--config', 'config/analysis.json', '--out', 'run', extra)
  status <- suppressWarnings(system2(command, vapply(args, shQuote, character(1))))
  if (status != 0L) stop('R stage failed: ', script)
}
tryCatch({
  if (stage == 'year') {
    if (is.na(item) || !item %in% years) stop('Invalid year.')
    download_year(item, 'data', TRUE)
    R('scripts/01_prepare_year.R', c('--year', item))
    outputs[[paste0('year-', item, '.rds')]] <- c(paste0('run/annual/', item, c('.parquet', '-success.rds')),
      paste0('run/', c('catalog', 'totals'), '/', item, '.parquet'),
      paste0('run/quality/', item, c('-input.tsv', '-categories.tsv')),
      paste0('run/metrics/year-', item, c('.json', '-session.txt')))
  } else if (stage == 'merge') {
    for (year in years) unpack_bundle(file.path(transfer, paste0('year-', year, '.rds')), project)
    review <- file.path(transfer, 'match_review.tsv')
    if (file.exists(review)) {
      dir.create('run/audit', recursive = TRUE, showWarnings = FALSE)
      file.copy(review, 'run/audit/match_review.tsv', overwrite = TRUE)
    }
    R('scripts/02_build_shards.R')
    outputs[['review-bundle.rds']] <- c('run/audit', 'run/format_month_totals.parquet', 'run/merge_success.rds', 'run/metrics', 'run/job_status')
    for (s in seq_len(cfg$n_shards)) outputs[[sprintf('shard-%04d-input.rds', s)]] <-
      c(sprintf('run/shards/%04d', s), 'run/merge_success.rds', 'run/audit/review_expected.parquet')
  } else if (stage %in% c('audit', 'fit')) {
    if (stage == 'audit') unpack_bundle(file.path(transfer, 'review-bundle.rds'), project) else {
      if (is.na(item) || item < 1L || item > cfg$n_shards) stop('Invalid shard.')
      unpack_bundle(file.path(transfer, sprintf('shard-%04d-input.rds', item)), project)
    }
    dir.create('run/audit', recursive = TRUE, showWarnings = FALSE)
    if (!file.copy(file.path(transfer, 'match_review.tsv'), 'run/audit/match_review.tsv', overwrite = TRUE)) stop('Missing review table.')
    if (stage == 'audit') {
      R('scripts/check_audit.R', c('--allow-unreviewed', allow))
      outputs[['audit-ok.rds']] <- character()
    } else {
      R('scripts/03_fit_shard.R', c('--shard', item, '--allow-unreviewed', allow))
      outputs[[sprintf('fit-shard-%04d.rds', item)]] <- c(sprintf('run/fits/shard-%04d', item) |> paste0(c('.parquet', '-success.rds')),
        paste0(sprintf('run/metrics/fit-%04d', item), c('.json', '-session.txt')))
    }
  } else {
    unpack_bundle(file.path(transfer, 'review-bundle.rds'), project)
    for (s in seq_len(cfg$n_shards)) {
      unpack_bundle(file.path(transfer, sprintf('shard-%04d-input.rds', s)), project)
      unpack_bundle(file.path(transfer, sprintf('fit-shard-%04d.rds', s)), project)
    }
    file.copy(file.path(transfer, 'match_review.tsv'), 'run/audit/match_review.tsv', overwrite = TRUE)
    R('scripts/04_compare_plot.R', c('--allow-unreviewed', allow))
  }
  success <- TRUE
}, error = function(e) { error <<- conditionMessage(e); message(error) })
write_json(list(stage = stage_id, success = success, error = error,
                elapsed_seconds = proc.time()[['elapsed']] - started, job_id = Sys.getenv('DSCP_JOB_ID')), status_path)
if (stage == 'compare') {
  copy_outputs(project, file.path(transfer, 'results'), c('run/results', 'run/metrics', 'run/job_status',
    'config/analysis.json', 'config/format_map.tsv', 'config/match_overrides.tsv'))
} else {
  if (!length(outputs)) {
    names <- switch(stage, year = paste0('year-', item, '.rds'), audit = 'audit-ok.rds',
      fit = sprintf('fit-shard-%04d.rds', item), merge = c('review-bundle.rds', sprintf('shard-%04d-input.rds', seq_len(cfg$n_shards))))
    outputs <- setNames(rep(list(character()), length(names)), names)
  }
  for (name in names(outputs)) pack_bundle(file.path(transfer, name), project, c(outputs[[name]], status_path))
}
if (stage == 'merge') for (name in c('match_review.tsv', 'match_candidates.tsv')) {
  source <- file.path('run/audit', name)
  if (file.exists(source)) file.copy(source, file.path(transfer, name), overwrite = TRUE)
  else writeLines('# Merge failed; inspect error log.', file.path(transfer, name))
}
if (stage == 'year') {
  raw <- file.path(project, 'data/monthly_csv')
  if (dir.exists(raw) && bundle_inside(raw, project)) unlink(raw, recursive = TRUE)
  unlink(Sys.glob(file.path(project, 'data/spl-checkouts_*.zip*')))
}
quit(status = if (success) 0L else 1L)
