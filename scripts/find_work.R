#!/usr/bin/env Rscript
source('R/common.R')
ctx <- init_context()
query <- ctx$args$query
if (is.null(query) || !nzchar(normalize_title(query))) stop('Supply --query with part of a book title.')
catalog <- read_pq(file.path(ctx$out, 'matching', 'catalog_variants.parquet'))
map <- read_pq(file.path(ctx$out, 'matching', 'normalized_key_map.parquet'))
matches <- catalog[stringi::stri_detect_fixed(title_norm, normalize_title(query))]
matches <- merge(matches, map, by = c('title_norm', 'creator_norm'))
setorder(matches, work_id, format, title_norm, creator_norm)
if (!nrow(matches)) stop('No normalized title matches. Try a shorter title fragment.')
columns <- c('work_id', 'include', 'title_norm', 'creator_norm', 'format', 'title_example', 'creator_example')
matches <- matches[, ..columns]
if (!is.null(ctx$args$save)) write_tsv(matches, ctx$args$save) else fwrite(matches, sep = '\t', na = '', quote = 'auto')
