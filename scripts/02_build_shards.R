#!/usr/bin/env Rscript
source('R/common.R')
ctx <- init_context()
for (year in ctx$years) require_marker(file.path(ctx$out, 'annual', paste0(year, '-success.rds')), ctx$signature)
overrides <- read_overrides(ctx)
catalog <- rbindlist(lapply(ctx$years, function(year) read_pq(file.path(ctx$out, 'catalog', paste0(year, '.parquet')))))
catalog <- catalog[, .(checkouts = sum(checkouts), source_rows = sum(source_rows),
                       title_example = short_examples(title_example), creator_example = short_examples(creator_example)),
                   by = .(title_norm, creator_norm, format)]
keys <- unique(catalog[, .(title_norm, creator_norm)])
setorder(keys, title_norm, creator_norm)
keys[, work_id := work_ids(work_key(title_norm, creator_norm))]
if (anyDuplicated(keys$work_id)) stop('Unexpected work ID collision.')
keys[, `:=`(include = TRUE, manual_override = FALSE)]
if (nrow(overrides)) {
  missing <- overrides[!keys, on = .(title_norm, creator_norm)]
  if (nrow(missing)) stop('Override key not found in normalized catalog. Use exact title_norm/creator_norm values.')
  for (i in seq_len(nrow(overrides))) {
    x <- overrides[i]
    index <- which(keys$title_norm == x$title_norm & keys$creator_norm == x$creator_norm)
    keys[index, `:=`(include = x$include == 'TRUE', manual_override = TRUE)]
    if (!is.na(x$work_id)) keys[index, work_id := x$work_id]
  }
}
write_pq(keys, file.path(ctx$out, 'matching', 'normalized_key_map.parquet'))
write_pq(catalog, file.path(ctx$out, 'matching', 'catalog_variants.parquet'))
catalog <- merge(catalog, keys, by = c('title_norm', 'creator_norm'), all.x = TRUE)
work_formats <- catalog[include == TRUE, .(checkouts = sum(checkouts)), by = .(work_id, format)]
eligible <- work_formats[checkouts > 0, .(eligible = 'print' %in% format && any(format != 'print')), by = work_id][eligible == TRUE, work_id]
map <- keys[include == TRUE & work_id %in% eligible]
if (!nrow(map)) stop('No cross-format works containing print were found. Inspect matching/catalog_variants.parquet and normalization/overrides.')
work_catalog <- catalog[work_id %in% eligible & include == TRUE,
  .(formats = paste(sort(unique(format)), collapse = ', '),
    display_title = sort(unique(title_norm[format == 'print']))[1],
    display_creator = sort(unique(creator_norm[format == 'print']))[1],
    title_examples = short_examples(paste(format, title_example, sep = ': '), 6L),
    creator_examples = short_examples(creator_example, 6L), normalized_keys = uniqueN(work_key(title_norm, creator_norm)),
    manual_override = any(manual_override), total_checkouts = sum(checkouts)), by = work_id]
setorder(work_catalog, work_id)
write_pq(work_catalog, file.path(ctx$out, 'matching', 'eligible_works.parquet'))
ids <- sort(unique(map$work_id))
shards <- data.table(work_id = ids, shard = vapply(ids, function(id) {
  as.integer(strtoi(substr(digest::digest(id, algo = 'sha256', serialize = FALSE), 1, 7), 16L) %% ctx$cfg$n_shards + 1L)
}, integer(1)))
map <- merge(map, shards, by = 'work_id')
write_tsv(shards, file.path(ctx$out, 'matching', 'work_shards.tsv'))
denominators <- rbindlist(lapply(ctx$years, function(y) read_pq(file.path(ctx$out, 'totals', paste0(y, '.parquet')))))
if (anyDuplicated(denominators[, .(format, period)])) stop('Duplicate format-month denominators.')
write_pq(denominators, file.path(ctx$out, 'format_month_totals.parquet'))
for (year in ctx$years) {
  d <- read_pq(file.path(ctx$out, 'annual', paste0(year, '.parquet')))
  d <- merge(d, map[, .(title_norm, creator_norm, work_id, shard)], by = c('title_norm', 'creator_norm'))
  d <- d[, .(checkouts = sum(checkouts)), by = .(work_id, shard, format, period, month_index)]
  d <- merge(d, denominators[, .(format, period, format_total)], by = c('format', 'period'), all.x = TRUE)
  if (anyNA(d$format_total) || any(d$checkouts > d$format_total)) stop('Invalid format denominator join.')
  for (s in seq_len(ctx$cfg$n_shards)) {
    write_pq(d[shard == s, .(work_id, format, period, month_index, checkouts, format_total)],
             file.path(ctx$out, 'shards', sprintf('%04d', s), paste0(year, '.parquet')))
  }
  message('Partitioned year ', year, ': ', nrow(d), ' eligible work-format-month rows')
}
override_signature <- sha(as.data.frame(overrides))
state <- list(signature = ctx$signature, override_signature = override_signature,
              merge_signature = sha(list(ctx$signature, override_signature, as.data.frame(shards))),
              years = ctx$years, n_shards = ctx$cfg$n_shards, works = length(ids))
write_rds(state, file.path(ctx$out, 'merge_success.rds'))
finish_stage(ctx, 'build-shards', list(eligible_works = length(ids)))
message('Matching complete; fit shards can run directly.')
