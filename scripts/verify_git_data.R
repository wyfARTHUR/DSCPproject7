#!/usr/bin/env Rscript
source('R/common.R')
need_packages(c('jsonlite', 'digest'))
manifest <- jsonlite::fromJSON('data/manifest.json')
for (i in seq_len(nrow(manifest$files))) {
  item <- manifest$files[i, ]
  path <- file.path('data', item$path)
  if (!file.exists(path) || file.info(path)$size != item$bytes ||
      digest::digest(file = path, algo = 'sha256') != item$sha256) stop('CSV checksum/size mismatch: ', path)
  if (i %% 12L == 0L || i == nrow(manifest$files)) message('Verified ', i, '/', nrow(manifest$files), ' CSV files')
}
