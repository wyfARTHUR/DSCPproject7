#!/usr/bin/env Rscript
source('R/common.R')
ctx <- init_context()
need_packages('ggplot2')
manifest <- jsonlite::fromJSON(ctx$cfg$input_manifest)
files <- as.data.table(manifest$files)
files[, period := sprintf('%04d-%02d', year, month)]
files <- files[period >= ctx$cfg$start_month & period <= ctx$cfg$end_month]
paths <- file.path(ctx$cfg$input_dir, sub('^monthly_csv/', '', files$path))
if (any(!file.exists(paths))) stop('Missing input files. Run git pull / check the configured input_dir.')
if (any(file.info(paths)$size != files$bytes)) stop('CSV sizes differ from the input manifest.')
months <- month_label(seq.int(month_number(ctx$cfg$start_month), month_number(ctx$cfg$end_month)))
missing <- setdiff(months, c(files$period, ctx$cfg$exclude_months))
if (length(missing)) stop('Unexplained input month gaps: ', paste(missing, collapse = ', '))
message('Input files: ', length(paths), '; input bytes: ', sum(files$bytes))
message('Configured years: ', paste(ctx$years, collapse = ', '))
message('Fit shards: ', ctx$cfg$n_shards)
message('Data preparation checks every CSV SHA-256 unless verify_input_hashes=FALSE.')
write_json(list(signature = ctx$signature, config = ctx$cfg,
                packages = setNames(lapply(c('data.table', 'arrow', 'stringi', 'digest', 'jsonlite', 'ggplot2'),
                                           function(p) as.character(packageVersion(p))),
                                    c('data.table', 'arrow', 'stringi', 'digest', 'jsonlite', 'ggplot2'))),
           file.path(ctx$out, 'run_config.json'))
finish_stage(ctx, 'check-environment', list(input_files = length(paths), input_bytes = sum(files$bytes)))
