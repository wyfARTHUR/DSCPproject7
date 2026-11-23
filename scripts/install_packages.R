#!/usr/bin/env Rscript
packages <- c('data.table', 'arrow', 'stringi', 'digest', 'jsonlite', 'ggplot2')
project_lib <- Sys.getenv('DSCP_R_LIB', '.Rlib')
dir.create(project_lib, recursive = TRUE, showWarnings = FALSE)
.libPaths(c(project_lib, .libPaths()))
missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) install.packages(missing, lib = project_lib, repos = 'https://cloud.r-project.org')
for (package in packages) {
  if (!requireNamespace(package, quietly = TRUE)) stop('Package installation failed: ', package)
  cat(package, as.character(packageVersion(package)), '\n')
}
