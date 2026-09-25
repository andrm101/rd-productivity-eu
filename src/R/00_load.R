# Stage shared setup: DuckDB connection, helper functions, package loading.
# Source this at the top of every R script / Quarto chunk.

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(modelsummary)
})

# ── Project root (works in RStudio, Rscript CLI, and sourced contexts) ────────
.resolve_proj_root <- function() {
  # 1. PROJ_ROOT environment variable (highest priority: set by knitr knit script)
  env_root <- Sys.getenv("PROJ_ROOT", unset = "")
  if (nzchar(env_root)) return(normalizePath(env_root, mustWork = FALSE))
  # 2. RStudio interactive
  if (requireNamespace("rstudioapi", quietly = TRUE) &&
      rstudioapi::isAvailable()) {
    ctx <- tryCatch(rstudioapi::getSourceEditorContext()$path, error = function(e) "")
    if (nzchar(ctx)) return(normalizePath(file.path(dirname(ctx), "..", ".."), mustWork = FALSE))
  }
  # 3. Rscript --file= argument
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("--file=", "", args[grep("--file=", args)])
  if (length(file_arg) && nzchar(file_arg))
    return(normalizePath(file.path(dirname(file_arg), "..", ".."), mustWork = FALSE))
  # 4. Working directory fallback
  normalizePath(getwd(), mustWork = FALSE)
}
proj_root <- .resolve_proj_root()

DB_PATH <- file.path(proj_root, "data", "panel.duckdb")

# ── Open a read-only DuckDB connection ────────────────────────────────────────
open_db <- function(read_only = TRUE) {
  if (!file.exists(DB_PATH)) {
    stop("panel.duckdb not found at: ", DB_PATH,
         "\nRun src/python/run_stage01.py first.")
  }
  duckdb::dbConnect(duckdb::duckdb(), dbdir = DB_PATH, read_only = read_only)
}

# ── Load the primary panel ────────────────────────────────────────────────────
load_panel <- function(con = NULL, close_con = TRUE,
                       primary_only = TRUE,
                       year_range   = c(1998L, 2024L)) {
  created <- is.null(con)
  if (created) con <- open_db()

  panel <- tbl(con, "panel_long") |>
    collect()

  if (primary_only) {
    eu_29 <- c(
      "AT","BE","BG","CY","CZ","DE","DK","EE","ES","FI","FR","GR","HR","HU",
      "IE","IT","IS","LT","LU","LV","MT","NL","NO","PL","PT","RO","SE","SI","SK","CH"
    )
    panel <- panel |> filter(country %in% eu_29)
  }

  panel <- panel |>
    filter(year >= year_range[1], year <= year_range[2]) |>
    arrange(country, year)

  if (created && close_con) dbDisconnect(con, shutdown = TRUE)
  panel
}

# ── Convenience: pdata.frame wrapper ─────────────────────────────────────────
make_pdata <- function(panel) {
  if (!requireNamespace("plm", quietly = TRUE)) stop("plm not installed.")
  plm::pdata.frame(panel, index = c("country", "year"))
}

# ── Theme for publication figures ────────────────────────────────────────────
theme_pub <- function(base_size = 11) {
  ggplot2::theme_minimal(base_size = base_size) +
    ggplot2::theme(
      panel.grid.minor   = element_blank(),
      axis.title         = element_text(size = base_size),
      axis.text          = element_text(size = base_size - 1),
      plot.title         = element_text(size = base_size + 1, face = "bold"),
      plot.caption       = element_text(size = base_size - 2, colour = "grey50"),
      legend.position    = "bottom",
      strip.text         = element_text(face = "bold")
    )
}

# ── Save figure helper (300 DPI) ──────────────────────────────────────────────
save_fig <- function(p, filename, width = 10, height = 6) {
  out_path <- file.path(proj_root, "figures", filename)
  dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
  ggplot2::ggsave(out_path, plot = p, width = width, height = height,
                  dpi = 300, units = "in")
  message("Figure saved: ", out_path)
  invisible(out_path)
}

message("00_load.R sourced. DB_PATH = ", DB_PATH)
