source('R/common.R')
source('chtc/bundle.R')
need_packages(c('data.table', 'arrow', 'jsonlite', 'digest', 'zip'))
# Sandbox subprocesses also need locally installed project libraries during tests.
Sys.setenv(R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep))
suppressPackageStartupMessages(library(data.table))
root <- normalizePath('.', winslash = '/')
dir.create('tests/.tmp', recursive = TRUE, showWarnings = FALSE)
# Build an absolute path explicitly: normalizePath() leaves a not-yet-existing path relative on macOS/Linux.
fixture <- file.path(root, 'tests/.tmp', basename(tempfile('chtc-R-')))
project <- file.path(fixture, 'source')
dir.create(project, recursive = TRUE)
for (folder in c('R', 'scripts', 'chtc', 'config')) {
  files <- list.files(folder, recursive = TRUE, full.names = TRUE, pattern = '\\.(R|sh|sub|dag|txt|sha256|json|tsv)$')
  for (path in files) {
    if (grepl('__pycache__|config/chtc.json$', path)) next
    target <- file.path(project, path)
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    file.copy(path, target)
  }
}
files <- list()
for (year in 2019:2021) for (month in 1:12) {
  period <- sprintf('%04d-%02d', year, month)
  if (period == '2020-05') next
  t <- (year-2019)*12+month-1
  rows <- list()
  for (format in c('print', 'ebook', 'digital_audio')) {
    half <- c(print = 6, ebook = 12, digital_audio = 18)[format]
    material <- c(print = 'BOOK', ebook = 'EBOOK', digital_audio = 'AUDIOBOOK')[format]
    d <- data.table(materialtype = unname(material), usageclass = if (format == 'print') 'Physical' else 'Digital',
      checkoutyear = year, checkoutmonth = month, checkouts = round(10000*2^(-t/half)),
      title = c('Alpha', 'Beta'), creator = c('Alice Writer', 'Bob Author'))
    if (format == 'print') d[, `:=`(title = paste(title, '/', creator), creator = c('Writer, Alice, 1970-', 'Author, Bob, 1970-'))]
    if (format == 'digital_audio') d[, title := paste0(title, ' (Unabridged)')]
    background <- copy(d[1]); background[, `:=`(title = 'Unmatchable background', creator = NA_character_, checkouts = 100000-sum(d$checkouts))]
    rows[[format]] <- rbind(d, background)
  }
  relative <- sprintf('monthly_csv/%d/spl-checkouts_%s_part01.csv', year, period)
  path <- file.path(fixture, 'dataset', relative)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  d <- rbindlist(rows); fwrite(d, path, na = 'NA')
  files[[length(files)+1L]] <- data.table(path = relative, year = year, month = month, part = 1L,
    rows = nrow(d), bytes = file.info(path)$size, sha256 = digest::digest(file = path, algo = 'sha256'))
}
manifest <- rbindlist(files)
dir.create(file.path(project, 'data'), showWarnings = FALSE)
write_json(list(files = manifest), file.path(project, 'data/manifest.json'))
writeLines('{}', file.path(fixture, 'dataset/year_manifest.json'))
archives <- list()
for (year in 2019:2021) {
  target_year <- year
  target <- file.path(fixture, paste0('spl-checkouts_', year, '.zip'))
  zip::zip(target, c(manifest[year == target_year, path], 'year_manifest.json'),
           root = file.path(fixture, 'dataset'), mode = 'mirror', include_directories = FALSE)
  archives[[length(archives)+1L]] <- data.table(year = year, filename = basename(target), bytes = file.info(target)$size,
    sha256 = digest::digest(file = target, algo = 'sha256'), url = paste0('file:///', sub('^/', '', normalizePath(target, winslash = '/'))))
}
write_json(list(archives = rbindlist(archives)), file.path(project, 'data/archives.json'))
cfg <- jsonlite::fromJSON(file.path(project, 'config/analysis.json'))
cfg$start_month <- '2019-01'; cfg$end_month <- '2021-12'; cfg$exclude_months <- '2020-05'; cfg$n_shards <- 3L
write_json(cfg, file.path(project, 'config/analysis.json'))
rscript <- file.path(R.home('bin'), 'Rscript')
bash <- Sys.getenv('BASH_EXE', Sys.which('bash'))
if (!nzchar(bash)) stop('Bash is required to test the short CHTC bootstrap.')
run <- file.path(project, 'run')
call <- function(command, args, cwd, expected = 0L) {
  previous <- getwd(); on.exit(setwd(previous)); setwd(cwd)
  log <- tempfile('log-', tmpdir = fixture)
  status <- suppressWarnings(system2(command, vapply(args, shQuote, character(1)), stdout = log, stderr = log))
  if (status != expected) stop(paste(readLines(log, warn = FALSE), collapse = '\n'))
  invisible(log)
}
call(rscript, c('--vanilla', 'chtc/make_templates.R'), project)
Sys.setenv(DSCP_CONTAINER_IMAGE = 'file:///staging/test/NOT_ACTUALLY_USED.sif')
call(bash, c('chtc/prepare.sh', 'prepare', 'run'), project)
names <- untar(file.path(run, 'code.tar.gz'), list = TRUE, tar = 'internal')
stopifnot(!any(grepl('\\.py$|/monthly_csv/|/\\.git/', names)), file.info(file.path(run, 'code.tar.gz'))$size < 1e6)
stopifnot(any(grepl('PARENT FITS CHILD COMPARE', readLines(file.path(run, 'fit.dag')))),
          any(grepl('PARENT MERGE CHILD FITS', readLines(file.path(run, 'all.dag')))))
job <- function(stage, item, expected = 0L) {
  scratch <- tempfile('sandbox-', tmpdir = fixture); dir.create(scratch)
  untar(file.path(run, 'code.tar.gz'), exdir = scratch, tar = 'internal')
  sandbox <- normalizePath(file.path(scratch, 'project'), winslash = '/')
  Sys.setenv(DSCP_JOB_SANDBOX = sandbox, DSCP_TRANSFER_DIR = run, DSCP_CPUS = '1', DSCP_JOB_ID = 'LOCAL_TEST')
  call(rscript, c('--vanilla', file.path(sandbox, 'chtc/run_job.R'), stage, item), project, expected)
  if (stage == 'year') stopifnot(!dir.exists(file.path(sandbox, 'data/monthly_csv')),
                                !length(Sys.glob(file.path(sandbox, 'data/spl-checkouts_*.zip'))))
  message('R CHTC sandbox passed: ', stage, ' ', item)
}
for (year in 2019:2021) job('year', year)
job('merge', 0)
stopifnot(file.exists(file.path(run, 'matching-bundle.rds')),
          !file.exists(file.path(run, 'match_review.tsv')))
call(bash, c('chtc/prepare.sh', 'fit', 'run'), project)
# A missing input still fails the job and returns a readable diagnostic bundle.
input <- file.path(run, 'shard-0001-input.rds')
stopifnot(file.rename(input, paste0(input, '.saved')))
job('fit', 1, expected = 1L)
failed <- readRDS(file.path(run, 'fit-shard-0001.rds'))
stopifnot(!jsonlite::fromJSON(rawToChar(failed$files[['run/job_status/fit-1.json']]$bytes))$success)
stopifnot(file.rename(paste0(input, '.saved'), input))
for (s in 1:3) job('fit', s)
job('compare', 0)
summary <- jsonlite::fromJSON(file.path(run, 'results/run/results/run_summary.json'))
stopifnot(summary$analysis_status == 'complete', summary$matching_method == matching_method())
comparison <- fread(file.path(run, 'results/run/results/format_comparison.tsv'))
stopifnot(nrow(comparison) == 4L, any(comparison$status == 'estimated'))
stopifnot(file.exists(file.path(run, 'results/run/results/figures/example_decay_curves.png')))
writeLines(c('title_norm\tcreator_norm\twork_id\tinclude\tnotes', 'beta\tbob author\t\tFALSE\tSynthetic exclusion'),
           file.path(project, 'config/match_overrides.tsv'))
call(bash, c('chtc/prepare.sh', 'merge', 'run'), project)
job('merge', 0)
revised_dir <- file.path(fixture, 'revised')
unpack_bundle(file.path(run, 'matching-bundle.rds'), revised_dir)
revised <- read_pq(file.path(revised_dir, 'run/matching/eligible_works.parquet'))
stopifnot(nrow(revised) == 1L, revised$display_title == 'alpha')
call(bash, c('chtc/prepare.sh', 'all', 'automatic'), project)
stopifnot('arguments = fit $(shard)' %in% readLines(file.path(project, 'automatic/fit.sub')),
          any(grepl('PARENT MERGE CHILD FITS', readLines(file.path(project, 'automatic/all.dag')))))
original <- readBin(file.path(project, 'R/common.R'), 'raw', n = file.info(file.path(project, 'R/common.R'))$size)
cat('\n# Simulated code change\n', file = file.path(project, 'R/common.R'), append = TRUE)
call(bash, c('chtc/prepare.sh', 'fit', 'run'), project, 2L)
writeBin(original, file.path(project, 'R/common.R'))
bad <- list(version = 1L, files = setNames(list(list(bytes = charToRaw('x'), sha256 = 'bad')), '../escaped.txt'))
badfile <- file.path(fixture, 'bad.rds'); saveRDS(bad, badfile)
error <- tryCatch({unpack_bundle(badfile, file.path(fixture, 'safe')); FALSE}, error = function(e) TRUE)
stopifnot(error)
Sys.setenv(DSCP_JOB_SANDBOX = root, DSCP_TRANSFER_DIR = run)
call(rscript, c('--vanilla', file.path(root, 'chtc/run_job.R'), 'year', '2019'), root, 1L)
cat('R-ONLY CHTC WORKFLOW TESTS PASSED: ', fixture, '\n', sep = '')
