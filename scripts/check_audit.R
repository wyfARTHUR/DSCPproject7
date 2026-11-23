#!/usr/bin/env Rscript
source('R/common.R')
ctx <- init_context()
state <- merge_state(ctx)
audit <- audit_state(ctx, state, identical(ctx$args[['allow-unreviewed']], 'true'))
cat(audit$status, ': ', audit$reviewed, '/', audit$required, ' audit rows reviewed\n', sep = '')
