#!/usr/bin/env Rscript
source('R/common.R')
source('chtc/bundle.R')
source('R/download.R')
need_packages(c('jsonlite', 'digest'))
args <- parse_args()
if (is.null(args$year)) stop('Supply --year, for example --year 2023 --output data_download --extract true.')
download_year(as.integer(args$year), if (is.null(args$output)) 'data' else args$output,
              identical(args$extract, 'true'))
