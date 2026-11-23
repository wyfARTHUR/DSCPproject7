source('R/common.R')
source('R/models.R')
need_packages(c('data.table', 'stringi', 'digest'))
suppressPackageStartupMessages(library(data.table))
cfg <- jsonlite::fromJSON('config/analysis.json')
near <- function(a, b, tol = 1e-5) stopifnot(isTRUE(all.equal(a, b, tolerance = tol, check.attributes = FALSE)))
stopifnot(normalize_title('Atlas [electronic resource] / Alice Writer.') == normalize_title('ATLAS (Unabridged)'))
stopifnot(normalize_creator('Writer, Alice, 1970-') == normalize_creator('Alice Writer'))
stopifnot(normalize_title('Atlas: a journey') != normalize_title('Atlas'))
stopifnot(normalize_title('Atlas (Abridged)') != normalize_title('Atlas (Unabridged)'))
near(month_number('2025-02') - month_number('2024-12'), 2)

t <- 0:30
fit <- fit_decay(month_number('2018-01') + t, exp(-log(2)*t/6), cfg)
stopifnot(fit$status == 'decaying'); near(fit$half_life, 6)
gaps <- c(0, 1, 2, 4, 7, 12, 18, 24, 30, 36, 42, 48, 54, 60)
fit <- fit_decay(month_number('2018-01') + gaps, exp(-log(2)*gaps/12), cfg)
near(fit$half_life, 12)
stopifnot(fit$post_peak_months == 13L, fit$post_peak_span == 60L)
stopifnot(fit_decay(0:11, exp(-0.1*(0:11)), cfg)$status == 'insufficient_post_peak_months')
stopifnot(fit_decay(0:12, exp(-0.1*(0:12)), cfg)$status == 'decaying')
flat <- fit_decay(month_number('2018-01') + 0:24, rep(1, 25), cfg)
stopifnot(flat$status == 'non_decaying', is.na(flat$half_life), flat$peak_month == '2018-01')
stopifnot(fit_decay(0:24, rep(0, 25), cfg)$status == 'no_positive_share')
boundary <- fit_decay(0:24, exp(-2*(0:24)), cfg)
stopifnot(boundary$status == 'rate_at_boundary', is.na(boundary$half_life))
zeros <- fit_decay(0:24, c(exp(-0.1*(0:18)), rep(0, 6)), cfg)
stopifnot(zeros$post_peak_months == 24L, zeros$zero_post_peak_months == 6L)
t <- 0:35
y <- ifelse(t <= 23, exp((t-23)/12), exp(-log(2)*(t-23)/6))
cross_year <- fit_decay(month_number('2018-01') + t, y, cfg)
stopifnot(cross_year$peak_month == '2019-12', cross_year$post_peak_months == 12L)
near(cross_year$half_life, 6)

# Independently compare the within estimator/covariance with an explicit dummy regression.
d <- CJ(book = 1:20, format = c('print', 'ebook', 'digital_audio'))
d[, `:=`(work_id = paste0('b', book), status = 'decaying')]
d[, half_life := (book + 2) * c(print = 1, ebook = 2, digital_audio = 3)[format] * exp(sin(book * match(format, c('print', 'ebook', 'digital_audio')))/20)]
result <- compare_formats(d)
d[, format_factor := relevel(factor(format), 'print')]
model <- lm(log(half_life) ~ factor(work_id) + format_factor, data = d)
M <- model.matrix(model)
U <- rowsum(M * residuals(model), d$work_id, reorder = FALSE)
B <- solve(crossprod(M))
G <- uniqueN(d$work_id); N <- nrow(d)
V <- G/(G-1) * (N-1)/df.residual(model) * B %*% crossprod(U) %*% B
for (target_format in c('ebook', 'digital_audio')) {
  term <- paste0('format_factor', target_format)
  near(result[format == target_format, estimate_log_ratio], coef(model)[term])
  near(result[format == target_format, std_error], sqrt(V[term, term]))
}
extra <- data.table(work_id = 'no_print', format = c('ebook', 'digital_audio'), status = 'decaying', half_life = c(1e6, 2e6))
with_extra <- compare_formats(rbindlist(list(d[, .(work_id, format, status, half_life)], extra)))
near(result$estimate_log_ratio, with_extra$estimate_log_ratio)
stopifnot(all(with_extra$books == 20L))
cat('MODEL TESTS PASSED\n')
