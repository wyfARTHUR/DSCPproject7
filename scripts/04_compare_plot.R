#!/usr/bin/env Rscript
source('R/common.R')
source('R/models.R')
ctx <- init_context()
need_packages('ggplot2')
state <- merge_state(ctx)
for (s in seq_len(ctx$cfg$n_shards)) {
  marker <- require_marker(file.path(ctx$out, 'fits', sprintf('shard-%04d-success.rds', s)), ctx$signature)
  if (!identical(marker$merge_signature, state$merge_signature)) stop('Stale fit shard: ', s)
}
fits <- rbindlist(lapply(seq_len(ctx$cfg$n_shards), function(s) read_pq(file.path(ctx$out, 'fits', sprintf('shard-%04d.parquet', s)))), use.names = TRUE)
if (anyDuplicated(fits[, .(scenario, work_id, format)])) stop('Duplicate fit results.')
comparison <- rbindlist(lapply(c('main', 'omit_pandemic'), function(label) {
  value <- compare_formats(fits[scenario == label])
  value[, scenario := label]
  value
}))
comparison[, matching_method := matching_method()]
status <- fits[, .(fits = .N), by = .(scenario, format, status)]
results <- file.path(ctx$out, 'results')
figures <- file.path(results, 'figures')
dir.create(figures, recursive = TRUE, showWarnings = FALSE)
write_pq(fits, file.path(results, 'all_fits.parquet'))
write_tsv(comparison, file.path(results, 'format_comparison.tsv'))
write_tsv(status, file.path(results, 'fit_status_counts.tsv'))
write_tsv(fits[status == 'non_decaying'], file.path(results, 'non_decaying.tsv'))
write_tsv(fits[status %in% c('insufficient_post_peak_months', 'rate_at_boundary', 'no_positive_share')],
          file.path(results, 'unestimable.tsv'))
caption <- 'Automatic title/creator matching; comparisons are descriptive'
theme <- ggplot2::theme_minimal(base_size = 11) +
  ggplot2::theme(plot.caption = ggplot2::element_text(hjust = 0), panel.grid.minor = ggplot2::element_blank())
save_plot <- function(plot, name, width = 8, height = 5) {
  ggplot2::ggsave(file.path(figures, paste0(name, '.png')), plot, width = width, height = height, dpi = 160)
  ggplot2::ggsave(file.path(figures, paste0(name, '.pdf')), plot, width = width, height = height)
}
totals <- read_pq(file.path(ctx$out, 'format_month_totals.parquet'))
totals[, date := as.Date(paste0(period, '-01'))]
p <- ggplot2::ggplot(totals, ggplot2::aes(date, format_total, color = format)) +
  ggplot2::geom_line() + ggplot2::labs(x = NULL, y = 'Monthly checkouts', color = 'Format',
    title = 'Total monthly checkouts by format', caption = caption) + theme
save_plot(p, 'monthly_format_totals')
good <- comparison[is.finite(ratio_to_print)]
if (nrow(good)) {
  p <- ggplot2::ggplot(good, ggplot2::aes(ratio_to_print, format)) +
    ggplot2::geom_vline(xintercept = 1, linetype = 2, color = 'grey50') +
    ggplot2::geom_segment(ggplot2::aes(x = ci_low, xend = ci_high, yend = format), na.rm = TRUE) +
    ggplot2::geom_point(size = 2.5) + ggplot2::scale_x_log10() + ggplot2::facet_wrap(~scenario) +
    ggplot2::labs(x = 'Half-life ratio to print (book fixed effects; 95% cluster-robust CI)', y = NULL,
                  title = 'Estimated digital-to-print half-life ratios', caption = caption) + theme
} else {
  p <- ggplot2::ggplot() + ggplot2::annotate('text', x = 0, y = 0, label = 'No comparable decaying book-format pairs') +
    ggplot2::labs(title = 'No estimable fixed-effect comparison', caption = caption) + ggplot2::theme_void()
}
save_plot(p, 'half_life_comparison', width = 10)
if (nrow(status)) {
  p <- ggplot2::ggplot(status, ggplot2::aes(format, fits, fill = status)) +
    ggplot2::geom_col(position = 'fill') + ggplot2::facet_wrap(~scenario) +
    ggplot2::labs(x = NULL, y = 'Fraction of book-format fits', fill = 'Fit status',
                  title = 'Fit eligibility and decay status', caption = caption) + theme
  save_plot(p, 'fit_status', width = 10)
}
# Illustrative examples are the highest-checkout comparable works, not selected by effect size.
comparable <- fits[scenario == 'main' & status == 'decaying',
                   .(ok = 'print' %in% format && any(format != 'print')), by = work_id][ok == TRUE, work_id]
catalog <- read_pq(file.path(ctx$out, 'matching', 'eligible_works.parquet'))
examples <- head(catalog[work_id %in% comparable][order(-total_checkouts, work_id)], 4L)
if (nrow(examples)) {
  shards <- fread(file.path(ctx$out, 'matching', 'work_shards.tsv'))
  shard_ids <- unique(shards[work_id %in% examples$work_id, shard])
  observed <- rbindlist(lapply(shard_ids, function(s) rbindlist(lapply(ctx$years, function(year) {
    read_pq(file.path(ctx$out, 'shards', sprintf('%04d', s), paste0(year, '.parquet')))[work_id %in% examples$work_id]
  }))))[format_total > 0]
  observed <- complete_zero_months(observed, totals)
  observed[, `:=`(share = checkouts/format_total, date = as.Date(paste0(period, '-01')))]
  curves <- merge(observed, fits[scenario == 'main' & status == 'decaying', .(work_id, format, peak_month, beta)],
                  by = c('work_id', 'format'))
  curves <- curves[period >= peak_month]
  curves[, predicted := {
    t <- month_index - month_number(peak_month[1])
    b <- beta[1]; z <- exp(b * (t - if (b >= 0) max(t) else min(t)))
    sum(share*z) / sum(z*z) * z
  }, by = .(work_id, format)]
  labels <- data.table(work_id = examples$work_id,
    label = paste0(seq_len(nrow(examples)), '. ', vapply(examples$display_title, function(title) {
      text <- if (nchar(title) > 80L) paste0(substr(title, 1, 77), '...') else title
      paste(stringi::stri_wrap(text, width = 40L), collapse = '\n')
    }, character(1)), '\n', examples$display_creator))
  observed <- merge(observed, labels, by = 'work_id')
  curves <- merge(curves, labels, by = 'work_id')
  p <- ggplot2::ggplot(observed, ggplot2::aes(date, share, color = format)) +
    ggplot2::geom_point(size = 0.8, alpha = 0.65) +
    ggplot2::geom_line(data = curves, ggplot2::aes(y = predicted), linewidth = 0.7) +
    ggplot2::facet_wrap(~label, scales = 'free_y') +
    ggplot2::labs(x = NULL, y = 'Share of all checkouts in the same format', color = 'Format',
                  title = 'Observed shares and fitted post-peak curves', caption = caption) + theme
  save_plot(p, 'example_decay_curves', width = 12, height = 7)
  write_tsv(examples, file.path(results, 'example_works.tsv'))
}
write_json(list(analysis_status = 'complete', matching_method = matching_method(),
                fit_rows = nrow(fits), eligible_works = state$works,
                calendar_start = ctx$cfg$start_month, calendar_end = ctx$cfg$end_month,
                excluded_months = ctx$cfg$exclude_months,
                pandemic_sensitivity_window = c(ctx$cfg$pandemic_start, ctx$cfg$pandemic_end),
                method = 'Unweighted nonlinear least squares exponential share decay; log-half-life book fixed effects; book-clustered CR1 covariance',
                limitations = c('Observational comparisons; no causal effect of format is identified',
                  'Inventory, licensing, availability and left/right censoring are not controlled',
                  'Absent work-month rows after first appearance are treated as zero checkouts (SPL lists only titles checked out that month)',
                  'Fixed-effect comparisons condition on estimable decaying print and digital fits',
                  'Cluster intervals do not propagate uncertainty from estimated individual decay curves',
                  'Work matches use configured title/creator normalization rules without manual review')),
           file.path(results, 'run_summary.json'))
finish_stage(ctx, 'compare-plot', list(comparison_rows = nrow(comparison)))
