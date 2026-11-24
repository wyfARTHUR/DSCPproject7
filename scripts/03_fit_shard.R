#!/usr/bin/env Rscript
source('R/common.R')
source('R/models.R')
ctx <- init_context()
state <- merge_state(ctx)
s <- as.integer(ctx$args$shard)
if (length(s) != 1L || is.na(s) || s < 1L || s > ctx$cfg$n_shards) stop('Supply a valid --shard.')
audit <- audit_state(ctx, state, identical(ctx$args[['allow-unreviewed']], 'true'))
d <- rbindlist(lapply(ctx$years, function(year) read_pq(file.path(ctx$out, 'shards', sprintf('%04d', s), paste0(year, '.parquet')))))
d <- d[!work_id %in% audit$rejected & format_total > 0]
if (anyDuplicated(d[, .(work_id, format, month_index)])) stop('Duplicate work-format-month rows after merging years.')
totals <- read_pq(file.path(ctx$out, 'format_month_totals.parquet'))
d <- complete_zero_months(d, totals)
d[, share := checkouts / format_total]
scenarios <- c('main', 'omit_pandemic')
results <- lapply(scenarios, function(scenario) {
  x <- copy(d)
  if (scenario == 'omit_pandemic') x <- x[period < ctx$cfg$pandemic_start | period > ctx$cfg$pandemic_end]
  if (!nrow(x)) {
    model <- as.data.table(fit_decay(integer(), numeric(), ctx$cfg))[0]
    model[, `:=`(work_id = character(), format = character())]
  } else {
    model <- x[, fit_decay(month_index, share, ctx$cfg), by = .(work_id, format)]
  }
  model[, `:=`(scenario = scenario, shard = s, audit_status = audit$status)]
  model
})
fits <- rbindlist(results, use.names = TRUE)
write_pq(fits, file.path(ctx$out, 'fits', sprintf('shard-%04d.parquet', s)))
write_rds(list(signature = ctx$signature, merge_signature = state$merge_signature,
               audit_signature = audit$signature, audit_status = audit$status),
          file.path(ctx$out, 'fits', sprintf('shard-%04d-success.rds', s)))
finish_stage(ctx, sprintf('fit-%04d', s), list(fits = nrow(fits), audit_status = audit$status))
