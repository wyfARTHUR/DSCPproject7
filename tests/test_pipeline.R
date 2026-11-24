source('R/common.R')
ctx0 <- init_context()
dir.create('tests/.tmp', recursive = TRUE, showWarnings = FALSE)
fixture <- normalizePath(tempfile('pipeline-', tmpdir = 'tests/.tmp'), mustWork = FALSE, winslash = '/')
dir.create(fixture, recursive = TRUE)
cfg <- jsonlite::fromJSON('config/analysis.json')
cfg$input_dir <- file.path(fixture, 'monthly_csv')
cfg$input_manifest <- file.path(fixture, 'manifest.json')
cfg$match_overrides <- file.path(fixture, 'overrides.tsv')
cfg$start_month <- '2018-01'; cfg$end_month <- '2022-12'
cfg$exclude_months <- '2020-05'
cfg$n_shards <- 4L
cfg$audit_sample_size <- 200L
cfg_path <- file.path(fixture, 'config.R')
dput(cfg, cfg_path)
out <- file.path(fixture, 'run')
manifest_entries <- list()
titles <- c('Atlas', 'Beta', 'Gamma', 'Flat', 'Zero Tail', 'Excluded Work', 'RejectMe')
formats <- c('print', 'ebook', 'digital_audio')
authors <- c('Alice Writer', 'Bob Smith', 'Carol Jones', 'Dan Reader', 'Eve Story', 'Fox Author', 'Gia Author')
peak <- month_number('2019-12')
for (m in seq.int(month_number(cfg$start_month), month_number(cfg$end_month))) {
  period <- month_label(m)
  if (period %in% cfg$exclude_months) next
  records <- list()
  for (f in formats) {
    format_rows <- list()
    for (b in seq_along(titles)) {
      if (b == 2 && f == 'print' && period == '2020-04') next
      half <- c(print = 6, ebook = 12, digital_audio = 18)[f] * if (b == 2) 1.5 else 1
      count <- round(10000 * if (m <= peak) exp((m - peak)/12) else 2^(-(m - peak)/half))
      if (b == 4) count <- 100
      if (b == 5 && m - peak >= 15) count <- 0
      if (f == 'digital_audio' && period == '2021-06') count <- 0
      raw_title <- titles[b]
      raw_creator <- authors[b]
      material <- c(print = 'BOOK', ebook = 'EBOOK', digital_audio = 'AUDIOBOOK')[f]
      usage <- if (f == 'print') 'Physical' else 'Digital'
      if (f == 'print') {
        parts <- strsplit(authors[b], ' ', fixed = TRUE)[[1]]
        raw_creator <- paste0(parts[2], ', ', parts[1], ', 1970-')
        raw_title <- paste0(raw_title, ' / ', authors[b], '.')
        if (b == 3) material <- 'LARGEPRINT'
      }
      if (f == 'ebook' && b == 1) raw_title <- 'Atlas: A journey'
      if (f == 'digital_audio') raw_title <- paste0(raw_title, ' (Unabridged)')
      row <- data.table(materialtype = unname(material), usageclass = usage,
                        checkoutyear = m %/% 12L, checkoutmonth = m %% 12L + 1L,
                        checkouts = count, title = raw_title, creator = raw_creator)
      if (b == 1 && f == 'print') {
        row[, checkouts := floor(count/2)]
        second <- copy(row); second[, `:=`(checkouts = count - floor(count/2), materialtype = 'REGPRINT')]
        format_rows[[length(format_rows)+1L]] <- second
      }
      format_rows[[length(format_rows)+1L]] <- row
    }
    book_rows <- rbindlist(format_rows)
    total <- if (f == 'digital_audio' && period == '2021-06') 0 else 100000
    background <- data.table(materialtype = c(print = 'BOOK', ebook = 'EBOOK', digital_audio = 'AUDIOBOOK')[f],
      usageclass = if (f == 'print') 'Physical' else 'Digital', checkoutyear = m %/% 12L,
      checkoutmonth = m %% 12L + 1L, checkouts = total - sum(book_rows$checkouts),
      title = 'Unmatchable background', creator = NA_character_)
    records[[f]] <- rbindlist(list(book_rows, background))
  }
  records[['nonbook']] <- data.table(materialtype = 'VIDEODISC', usageclass = 'Physical',
    checkoutyear = m %/% 12L, checkoutmonth = m %% 12L + 1L, checkouts = 5000,
    title = 'Not a book', creator = 'Some Director')
  d <- rbindlist(records)
  relative <- sprintf('monthly_csv/%04d/spl-checkouts_%s_part01.csv', m %/% 12L, period)
  file <- file.path(fixture, relative)
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  fwrite(d, file, na = 'NA')
  manifest_entries[[length(manifest_entries)+1L]] <- data.table(path = relative, year = m %/% 12L,
    month = m %% 12L + 1L, part = 1L, rows = nrow(d), bytes = file.info(file)$size,
    sha256 = digest::digest(file = file, algo = 'sha256'))
}
write_json(list(files = rbindlist(manifest_entries)), cfg$input_manifest)
overrides <- data.table(title_norm = c('atlas', 'atlas a journey', 'excluded work'),
  creator_norm = c('alice writer', 'alice writer', 'fox author'),
  work_id = c('manual_atlas', 'manual_atlas', NA_character_), include = c('TRUE', 'TRUE', 'FALSE'),
  notes = c('Synthetic alias test', 'Synthetic alias test', 'Synthetic exclusion test'))
write_tsv(overrides, cfg$match_overrides)
run <- function(script, extra = character(), success = TRUE) {
  logfile <- tempfile('log-', tmpdir = fixture)
  args <- c('--vanilla', script, '--config', cfg_path, '--out', out, extra)
  status <- suppressWarnings(system2(file.path(R.home('bin'), 'Rscript'), vapply(args, shQuote, character(1)), stdout = logfile, stderr = logfile))
  text <- readLines(logfile, warn = FALSE)
  if (success && status != 0L) stop(paste(text, collapse = '\n'))
  if (!success && status == 0L) stop('Expected this command to fail: ', script)
  invisible(text)
}
run('scripts/00_check_environment.R')
for (year in 2018:2022) run('scripts/01_prepare_year.R', c('--year', year))
run('scripts/02_build_shards.R')
totals <- read_pq(file.path(out, 'format_month_totals.parquet'))
stopifnot(all(totals[!(format == 'digital_audio' & period == '2021-06'), format_total] == 100000))
stopifnot(totals[format == 'digital_audio' & period == '2021-06', format_total] == 0)
stopifnot(!'2020-05' %in% totals$period)
map <- read_pq(file.path(out, 'audit', 'normalized_key_map.parquet'))
stopifnot(all(map[title_norm %in% c('atlas', 'atlas a journey'), work_id] == 'manual_atlas'))
shards <- fread(file.path(out, 'audit', 'work_shards.tsv'))
target_shard <- shards[work_id == 'manual_atlas', shard]
error <- run('scripts/03_fit_shard.R', c('--shard', target_shard), success = FALSE)
stopifnot(any(grepl('Manual match audit is incomplete', error, fixed = TRUE)))
run('scripts/03_fit_shard.R', c('--shard', target_shard, '--allow-unreviewed', 'true'))
prelim <- read_pq(file.path(out, 'fits', sprintf('shard-%04d.parquet', target_shard)))
stopifnot(all(prelim$audit_status == 'PRELIMINARY_UNREVIEWED'))
review_path <- file.path(out, 'audit', 'match_review.tsv')
review <- fread(review_path, colClasses = 'character', na.strings = '')
review[, `:=`(decision = 'accept', reviewer = 'synthetic-test')]
reject_id <- map[title_norm == 'rejectme', work_id]
review[work_id == reject_id, decision := 'reject']
write_tsv(review, review_path)
for (s in 1:4) run('scripts/03_fit_shard.R', c('--shard', s))
run('scripts/04_compare_plot.R')
fits <- read_pq(file.path(out, 'results', 'all_fits.parquet'))
atlas <- fits[scenario == 'main' & work_id == 'manual_atlas']
stopifnot(nrow(atlas) == 3L, all(atlas$peak_month == '2019-12'), all(atlas$status == 'decaying'))
for (f in formats) {
  expected <- c(print = 6, ebook = 12, digital_audio = 18)[f]
  stopifnot(abs(atlas[format == f, half_life] - expected) < 0.15)
}
stopifnot(atlas[format == 'print', post_peak_months] == 35L)
stopifnot(atlas[format == 'digital_audio', post_peak_months] == 34L)
stopifnot(atlas[format == 'print', post_peak_span] == 36L)
stopifnot(!any(fits$work_id %in% c(reject_id, map[title_norm == 'excluded work', work_id])))
# Absent source rows after first appearance are zero-filled, not dropped.
beta_print <- fits[scenario == 'main' & work_id == map[title_norm == 'beta', work_id] & format == 'print']
stopifnot(beta_print$post_peak_months == 35L, beta_print$zero_post_peak_months == 1L)
zero_tail <- fits[scenario == 'main' & work_id == map[title_norm == 'zero tail', work_id]]
stopifnot(nrow(zero_tail) == 3L, all(zero_tail[format != 'digital_audio', zero_post_peak_months] == 22L))
# Absent source rows after first appearance are zero-filled, not dropped.
beta_print <- fits[scenario == 'main' & work_id == map[title_norm == 'beta', work_id] & format == 'print']
stopifnot(beta_print$post_peak_months == 35L, beta_print$zero_post_peak_months == 1L)
zero_tail <- fits[scenario == 'main' & work_id == map[title_norm == 'zero tail', work_id]]
stopifnot(nrow(zero_tail) == 3L, all(zero_tail[format != 'digital_audio', zero_post_peak_months] == 22L))
stopifnot(any(fits$status == 'non_decaying'), any(fits$zero_post_peak_months > 0))
stopifnot(all(fits$audit_status == 'audit_sample_complete'))
comparison <- fread(file.path(out, 'results', 'format_comparison.tsv'))
stopifnot(nrow(comparison) == 4L, any(comparison$status == 'estimated'))
# Changed audit decisions/notes invalidate previously computed fit shards.
changed_review <- copy(review)
changed_review[1, notes := 'Changed after fitting']
write_tsv(changed_review, review_path)
stale_error <- run('scripts/04_compare_plot.R', success = FALSE)
stopifnot(any(grepl('Stale fit shard', stale_error, fixed = TRUE)))
write_tsv(review, review_path)
# A missing shard must block final aggregation rather than quietly produce partial results.
marker <- file.path(out, 'fits', 'shard-0004-success.rds')
saved <- readRDS(marker); unlink(marker)
run('scripts/04_compare_plot.R', success = FALSE)
saveRDS(saved, marker)
cat('PIPELINE TESTS PASSED: ', fixture, '\n', sep = '')
