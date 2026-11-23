#!/usr/bin/env Rscript
source('R/common.R')
ctx <- init_context()
year <- as.integer(ctx$args$year)
if (length(year) != 1L || is.na(year) || !year %in% ctx$years) stop('Supply --year within configured range.')
manifest <- jsonlite::fromJSON(ctx$cfg$input_manifest)
target_year <- year
files <- as.data.table(manifest$files)[get('year') == target_year]
files[, period := sprintf('%04d-%02d', get('year'), month)]
files <- files[period >= ctx$cfg$start_month & period <= ctx$cfg$end_month]
expected <- month_label(seq.int(month_number(ctx$cfg$start_month), month_number(ctx$cfg$end_month)))
expected <- expected[substr(expected, 1, 4) == as.character(year)]
missing <- setdiff(expected, c(files$period, ctx$cfg$exclude_months))
if (length(missing)) stop('Unexplained missing source months: ', paste(missing, collapse = ', '))
if (!nrow(files)) stop('No source CSV files for requested year.')
setorder(files, period, part)
aggregates <- catalogs <- totals <- quality <- categories <- vector('list', nrow(files))
selected <- c('materialtype', 'usageclass', 'checkoutyear', 'checkoutmonth', 'checkouts', 'title', 'creator')
map_key <- paste(ctx$fmap$materialtype, ctx$fmap$usageclass, sep = '\034')
for (i in seq_len(nrow(files))) {
  item <- files[i]
  relative <- sub('^monthly_csv/', '', item$path)
  path <- file.path(ctx$cfg$input_dir, relative)
  if (!file.exists(path) || file.info(path)$size != item$bytes) stop('Missing or wrong-size CSV: ', path)
  if (ctx$cfg$verify_input_hashes && digest::digest(file = path, algo = 'sha256') != item$sha256) stop('CSV checksum mismatch: ', path)
  d <- fread(file = path, select = selected, encoding = 'UTF-8', na.strings = c('', 'NA'),
             colClasses = list(character = c('materialtype', 'usageclass', 'title', 'creator'),
                               integer = c('checkoutyear', 'checkoutmonth'), numeric = 'checkouts'),
             showProgress = FALSE)
  if (nrow(d) != item$rows || anyNA(d$checkoutyear) || anyNA(d$checkoutmonth) ||
      any(d$checkoutyear != year | d$checkoutmonth != item$month)) stop('CSV row count/period mismatch: ', path)
  if (any(!is.finite(d$checkouts) | d$checkouts < 0 | d$checkouts != floor(d$checkouts))) stop('Invalid checkout count: ', path)
  d[, `:=`(materialtype = toupper(trimws(materialtype)), usageclass = toupper(trimws(usageclass)))]
  categories[[i]] <- d[, .(source_rows = .N, checkouts = sum(checkouts)), by = .(materialtype, usageclass)]
  d[, format := ctx$fmap$format[match(paste(materialtype, usageclass, sep = '\034'), map_key)]]
  input_rows <- nrow(d)
  d <- d[!is.na(format)]
  mapped_rows <- nrow(d)
  if (item$period %in% ctx$cfg$exclude_months) d <- d[0]
  d[, `:=`(period = item$period, month_index = month_number(item$period))]
  # The denominator precedes title/creator exclusion and cross-format matching.
  totals[[i]] <- d[, .(format_total = sum(checkouts), source_rows = .N), by = .(format, period, month_index)]
  d[, `:=`(title_norm = normalize_title(title), creator_norm = normalize_creator(creator))]
  valid <- !is.na(d$title_norm) & nzchar(d$title_norm) & !is.na(d$creator_norm) & nzchar(d$creator_norm)
  valid <- valid & !(tolower(trimws(d$title)) %in% c('<unknown title>', 'unknown title'))
  d <- d[which(valid)]
  quality[[i]] <- data.table(file = item$path, period = item$period, input_rows = input_rows,
                            mapped_rows = mapped_rows, matchable_rows = nrow(d),
                            excluded_month = item$period %in% ctx$cfg$exclude_months)
  catalogs[[i]] <- d[, .(source_rows = .N, checkouts = sum(checkouts),
                         title_example = short_examples(title), creator_example = short_examples(creator)),
                     by = .(title_norm, creator_norm, format)]
  aggregates[[i]] <- d[, .(checkouts = sum(checkouts)), by = .(title_norm, creator_norm, format, period, month_index)]
  message(item$period, ': ', input_rows, ' input rows; ', nrow(d), ' matchable rows')
}
counts <- rbindlist(aggregates)[, .(checkouts = sum(checkouts)), by = .(title_norm, creator_norm, format, period, month_index)]
catalog <- rbindlist(catalogs)[, .(source_rows = sum(source_rows), checkouts = sum(checkouts),
                                title_example = short_examples(title_example), creator_example = short_examples(creator_example)),
                            by = .(title_norm, creator_norm, format)]
denominators <- rbindlist(totals)[, .(format_total = sum(format_total), source_rows = sum(source_rows)),
                                by = .(format, period, month_index)]
write_pq(counts, file.path(ctx$out, 'annual', paste0(year, '.parquet')))
write_pq(catalog, file.path(ctx$out, 'catalog', paste0(year, '.parquet')))
write_pq(denominators, file.path(ctx$out, 'totals', paste0(year, '.parquet')))
write_tsv(rbindlist(quality), file.path(ctx$out, 'quality', paste0(year, '-input.tsv')))
write_tsv(rbindlist(categories)[, .(source_rows = sum(source_rows), checkouts = sum(checkouts)), by = .(materialtype, usageclass)],
          file.path(ctx$out, 'quality', paste0(year, '-categories.tsv')))
write_rds(list(signature = ctx$signature, year = year, input_rows = sum(files$rows), count_rows = nrow(counts)),
          file.path(ctx$out, 'annual', paste0(year, '-success.rds')))
finish_stage(ctx, paste0('year-', year), list(input_rows = sum(files$rows), count_rows = nrow(counts)))
