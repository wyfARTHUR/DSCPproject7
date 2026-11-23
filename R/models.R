# Exponential nonlinear least squares on shares, retaining explicit zero counts.
# The amplitude is profiled out analytically; a grid locates candidate minima.
fit_decay <- function(month, share, cfg) {
  order <- order(month)
  month <- month[order]; share <- share[order]
  valid <- is.finite(share) & share >= 0
  month <- month[valid]; share <- share[valid]
  empty <- list(status = 'no_positive_share', observed_months = length(month),
                peak_month = NA_character_, post_peak_months = 0L, post_peak_span = NA_integer_,
                zero_post_peak_months = 0L, beta = NA_real_, half_life = NA_real_,
                r_squared = NA_real_, scaled_rmse = NA_real_, left_boundary_peak = NA)
  if (!length(share) || max(share) <= 0) return(empty)
  peak <- which.max(share) # First calendar month wins an exact peak tie.
  t <- month[seq.int(peak, length(month))] - month[peak]
  y <- share[seq.int(peak, length(month))] / share[peak]
  empty$peak_month <- month_label(month[peak])
  empty$post_peak_months <- sum(t > 0)
  empty$post_peak_span <- max(t)
  empty$zero_post_peak_months <- sum(y[t > 0] == 0)
  empty$left_boundary_peak <- peak == 1L
  if (sum(t > 0) < cfg$min_post_peak_months) {
    empty$status <- 'insufficient_post_peak_months'
    return(empty)
  }
  profile <- function(beta, predict = FALSE) {
    z <- exp(beta * (t - if (beta >= 0) max(t) else min(t)))
    amplitude <- sum(y * z) / sum(z * z)
    fitted <- amplitude * z
    if (predict) fitted else sum((y - fitted)^2)
  }
  bound <- cfg$max_abs_rate
  grid <- sort(unique(c(seq(-bound, bound, length.out = 81L), 0)))
  scores <- vapply(grid, profile, numeric(1))
  candidates <- which(scores <= c(Inf, head(scores, -1L)) & scores <= c(tail(scores, -1L), Inf))
  estimates <- lapply(candidates, function(i) {
    interval <- grid[c(max(1L, i-1L), min(length(grid), i+1L))]
    if (diff(interval) == 0) return(c(beta = grid[i], sse = scores[i]))
    opt <- optimize(profile, interval, tol = 1e-9)
    c(beta = opt$minimum, sse = opt$objective)
  })
  estimates <- do.call(rbind, c(estimates, list(c(beta = 0, sse = profile(0)),
                                              c(beta = -bound, sse = profile(-bound)),
                                              c(beta = bound, sse = profile(bound)))))
  best <- estimates[which.min(estimates[, 'sse']), ]
  beta <- best[['beta']]
  if (abs(beta) <= cfg$rate_zero_tolerance) beta <- 0
  empty$beta <- beta
  empty$scaled_rmse <- sqrt(profile(beta) / length(y))
  total <- sum((y - mean(y))^2)
  empty$r_squared <- if (total > .Machine$double.eps) 1 - profile(beta)/total else NA_real_
  if (abs(beta) >= bound * (1 - 1e-5)) {
    empty$status <- 'rate_at_boundary'
  } else if (beta >= 0) {
    empty$status <- 'non_decaying'
  } else {
    empty$status <- 'decaying'
    empty$half_life <- log(2) / (-beta)
  }
  empty
}

# Within-book estimator; cluster-robust CR1 covariance with book-level clusters.
# A print edition and at least one digital edition must have estimable half-lives.
compare_formats <- function(fits) {
  formats <- c('ebook', 'digital_audio')
  template <- data.table::data.table(format = formats, estimate_log_ratio = NA_real_,
    std_error = NA_real_, ratio_to_print = NA_real_, ci_low = NA_real_, ci_high = NA_real_,
    books = 0L, observations = 0L, residual_df = 0L, status = 'no_comparable_books')
  x <- data.table::copy(fits[status == 'decaying' & is.finite(half_life) & half_life > 0])
  eligible <- x[, .(ok = 'print' %in% format && any(format != 'print')), by = work_id][ok == TRUE, work_id]
  x <- x[work_id %in% eligible]
  if (!nrow(x)) return(template)
  if (anyDuplicated(x[, .(work_id, format)])) stop('Duplicate book-format fit in fixed-effect comparison.')
  x[, y := log(half_life)]
  x[, y_within := y - mean(y), by = work_id]
  present <- formats[formats %in% x$format]
  X <- sapply(present, function(f) {
    v <- as.numeric(x$format == f)
    v - ave(v, x$work_id, FUN = mean)
  })
  X <- matrix(X, ncol = length(present), dimnames = list(NULL, present))
  if (qr(X)$rank != ncol(X)) stop('Fixed-effect comparison is not identifiable.')
  bread <- solve(crossprod(X))
  beta <- as.numeric(bread %*% crossprod(X, x$y_within))
  residual <- as.numeric(x$y_within - X %*% beta)
  G <- data.table::uniqueN(x$work_id); N <- nrow(x); K <- ncol(X)
  df <- N - G - K
  se <- rep(NA_real_, K)
  if (G > 1L && df > 0L) {
    scores <- rowsum(X * residual, x$work_id, reorder = FALSE)
    covariance <- (G/(G-1)) * ((N-1)/df) * bread %*% crossprod(scores) %*% bread
    se <- sqrt(pmax(0, diag(covariance)))
  }
  critical <- if (G > 1L && df > 0L) qt(0.975, df = G-1L) else NA_real_
  for (j in seq_along(present)) {
    i <- match(present[j], template$format)
    template[i, `:=`(estimate_log_ratio = beta[j], std_error = se[j],
      ratio_to_print = exp(beta[j]), ci_low = exp(beta[j] - critical * se[j]),
      ci_high = exp(beta[j] + critical * se[j]), books = G, observations = N,
      residual_df = df, status = if (is.finite(se[j])) 'estimated' else 'insufficient_cluster_df')]
  }
  template
}
