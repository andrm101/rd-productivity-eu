library(rmarkdown)
library(bookdown)
Sys.setenv(PROJ_ROOT = normalizePath("."))   # picked up by 00_load.R and Rmd setup
rmd_path <- normalizePath("reports/main.Rmd")
rmarkdown::render(
  input         = rmd_path,
  output_format = bookdown::pdf_document2(
    toc             = TRUE,
    toc_depth       = 3,
    number_sections = TRUE,
    latex_engine    = "xelatex"
  ),
  output_file   = "main.pdf",
  output_dir    = dirname(rmd_path),
  knit_root_dir = normalizePath("."),   # all chunk paths relative to project root
  quiet         = FALSE
)
cat("\nKnit complete. Output: reports/main.pdf\n")
