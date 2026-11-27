#!/usr/bin/env Rscript
# Maintainer/local-R utility. Committed templates let learn work without R.
source('R/common.R')
need_packages(c('jsonlite', 'digest'))
args <- parse_args()
cfg_path <- if (is.null(args$config)) 'config/analysis.json' else args$config
out <- if (is.null(args$out)) 'chtc/templates' else args$out
cfg <- jsonlite::fromJSON(cfg_path)
resources <- jsonlite::fromJSON('config/chtc.example.json')
years <- seq.int(as.integer(substr(cfg$start_month, 1, 4)), as.integer(substr(cfg$end_month, 1, 4)))
if (cfg$n_shards < 1L || cfg$n_shards != as.integer(cfg$n_shards)) stop('Invalid shard count.')
dir.create(out, recursive = TRUE, showWarnings = FALSE)
put <- function(name, text) {
  connection <- file(file.path(out, name), 'wb')
  on.exit(close(connection))
  writeBin(charToRaw(paste0(paste(text, collapse = '\n'), '\n')), connection)
}
submit <- function(stage, inputs, outputs, arguments, queue) {
  cpu <- resources[[paste0(stage, '_cpus')]]
  c('universe = container', 'container_image = @CONTAINER_IMAGE@', 'executable = job.sh',
    paste0('arguments = ', arguments),
    'should_transfer_files = YES', 'when_to_transfer_output = ON_EXIT',
    paste0('transfer_input_files = ', paste(c('code.tar.gz', inputs), collapse = ', ')),
    paste0('transfer_output_files = ', paste(outputs, collapse = ', ')),
    paste0('request_cpus = ', cpu), paste0('request_memory = ', resources[[paste0(stage, '_memory')]]),
    paste0('request_disk = ', resources[[paste0(stage, '_disk')]]),
    sprintf('environment = "DSCP_CPUS=%s DSCP_JOB_ID=$(Cluster).$(Process)"', cpu),
    paste0('log = logs/', stage, '_$(Cluster).log'), paste0('output = logs/', stage, '_$(Cluster)_$(Process).out'),
    paste0('error = logs/', stage, '_$(Cluster)_$(Process).err'),
    'requirements = (HasCHTCStaging == true)', queue)
}
shards <- sprintf('%04d', seq_len(cfg$n_shards))
put('years.txt', years)
put('shards.txt', shards)
put('analysis.sha256', digest::digest(file = cfg_path, algo = 'sha256'))
put('year.sub', submit('year', character(), 'year-$(year).rds', 'year $(year)', 'queue year from years.txt'))
put('pilot.sub', submit('year', character(), 'year-$(year).rds', 'year $(year)', paste0('queue year in (', years[1], ')')))
shard_inputs <- paste0('shard-', shards, '-input.rds')
put('merge.sub', submit('merge', paste0('year-', years, '.rds'),
  c('matching-bundle.rds', shard_inputs), 'merge 0', 'queue'))
put('fit.sub', submit('fit', 'shard-$(shard)-input.rds', 'fit-shard-$(shard).rds',
  'fit $(shard)', 'queue shard from shards.txt'))
put('compare.sub', submit('compare', c('matching-bundle.rds', shard_inputs,
  paste0('fit-shard-', shards, '.rds')), 'results', 'compare 0', 'queue'))
prepare <- c('JOB YEARS year.sub', 'JOB MERGE merge.sub', 'PARENT YEARS CHILD MERGE')
fit <- c('JOB FITS fit.sub', 'JOB COMPARE compare.sub', 'PARENT FITS CHILD COMPARE')
put('prepare.dag', prepare)
put('merge.dag', 'JOB MERGE merge.sub')
put('fit.dag', fit)
put('all.dag', c(prepare, fit, 'PARENT MERGE CHILD FITS'))
cat('Generated R-only job templates in ', out, '\n', sep = '')
