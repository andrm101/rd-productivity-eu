# Stage 05 — Local Projections (Jordà 2005)
#
# Estimating equation for each horizon h = 0, 1, …, H:
#
#   y_{i,t+h} - y_{i,t-1} = alpha^h_i + lambda^h_t
#                           + beta^h  * s_{it}
#                           + sum_{k=1}^{2} phi^h_k   * s_{i,t-k}
#                           + sum_{k=1}^{2} psi^h_k   * growth_y_{i,t-k}
#                           + gamma^h * X_{it}
#                           + eps^h_{it+h}
#
#   s_{it}   = diff_gerd_{it}   (1pp change in GERD/GDP — the shock)
#   y        = ln_y_pc           (log GDP per capita, PPS)
#   LHS      = cumulative log-growth from t-1 to t+h
#   X        = savings, tertiary_25_64, n_g_d, dtf  (contemporaneous)
#   FE       = country + year two-way
#   SEs      = Driscoll-Kraay (robust to CD and serial corr.)
#
# Lagged shock (s_{t-1}, s_{t-2}) and lagged outcome (growth_y_{t-1},
# growth_y_{t-2}) are included following Ramey & Zubairy (2018) to purge
# pre-existing serial correlation from the error.
#
# IRFs are plotted with 68% and 90% confidence bands.
#
# Three IRF sets:
#   LP1  Full N=29 primary panel
#   LP2  Close-to-frontier subsample (dtf <= median)
#   LP3  Catch-up subsample (dtf > median)

suppressPackageStartupMessages({
  library(fixest)
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(ggplot2)
})

.this_dir <- (function() {
  args <- commandArgs(trailingOnly = FALSE)
  f <- sub("--file=", "", args[grep("--file=", args)])
  if (length(f) && nzchar(f)) return(dirname(normalizePath(f)))
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    ctx <- tryCatch(rstudioapi::getSourceEditorContext()$path, error = function(e) "")
    if (nzchar(ctx)) return(dirname(normalizePath(ctx)))
  }
  getwd()
})()
source(file.path(.this_dir, "00_load.R"))

H_MAX <- 8L   # maximum horizon (years)

# ── Load and prepare ──────────────────────────────────────────────────────────
panel <- load_panel(primary_only = TRUE, year_range = c(1998L, 2024L)) |>
  mutate(
    savings  = savings_pct / 100,
    year_int = as.integer(year)
  ) |>
  arrange(country, year_int)

dtf_med <- median(panel$dtf, na.rm = TRUE)
cat(sprintf("Panel: N=%d, T=%d. DTF median=%.3f\n",
            n_distinct(panel$country), n_distinct(panel$year), dtf_med))

# ── Build lead outcomes for each horizon ─────────────────────────────────────
# outcome_h = ln_y_pc_{t+h} - ln_y_pc_{t-1}  (cumulative change from t-1)
panel <- panel |>
  group_by(country) |>
  mutate(
    lag_ln_y    = lag(ln_y_pc, 1),
    diff_gerd_l1 = lag(diff_gerd, 1),
    diff_gerd_l2 = lag(diff_gerd, 2),
    growth_y_l1  = lag(growth_y, 1),
    growth_y_l2  = lag(growth_y, 2)
  ) |>
  ungroup()

for (h in 0:H_MAX) {
  panel <- panel |>
    group_by(country) |>
    mutate(!!paste0("out_h", h) := lead(ln_y_pc, h) - lag_ln_y) |>
    ungroup()
}

# ── LP estimator ──────────────────────────────────────────────────────────────
run_lp <- function(df, label, H = H_MAX) {
  cat(sprintf("\nRunning LP: %s  (N=%d)\n", label, n_distinct(df$country)))

  map_dfr(0:H, function(h) {
    outcome_col <- paste0("out_h", h)

    fml <- as.formula(paste(
      outcome_col,
      "~ diff_gerd + diff_gerd_l1 + diff_gerd_l2",
      "+ growth_y_l1 + growth_y_l2",
      "+ savings + tertiary_25_64 + n_g_d + dtf",
      "| country + year_int"
    ))

    mod <- tryCatch(
      fixest::feols(fml,
                    data     = df,
                    panel.id = ~ country + year_int,
                    vcov     = "DK"),
      error = function(e) NULL
    )
    if (is.null(mod)) return(tibble(horizon=h, coef=NA_real_, se=NA_real_))

    b  <- coef(mod)["diff_gerd"]
    se <- sqrt(diag(vcov(mod)))["diff_gerd"]
    tibble(horizon = h, coef = b, se = se,
           ci68_lo = b - 1.00*se, ci68_hi = b + 1.00*se,
           ci90_lo = b - 1.645*se, ci90_hi = b + 1.645*se,
           n_obs = nobs(mod), label = label)
  })
}

irf_full   <- run_lp(panel,                            "Full panel (N=29)")
irf_close  <- run_lp(panel |> filter(dtf <= dtf_med),  "Close to frontier")
irf_far    <- run_lp(panel |> filter(dtf >  dtf_med),  "Catch-up (far)")

irf_all <- bind_rows(irf_full, irf_close, irf_far) |>
  filter(!is.na(coef))

cat("\n── IRF coefficients (full panel) ──\n")
print(irf_full |> select(horizon, coef, se, ci90_lo, ci90_hi, n_obs))

# ── IRF plot ──────────────────────────────────────────────────────────────────
irf_plot <- function(df, title_str, filename) {
  p <- ggplot(df, aes(x = horizon)) +
    geom_hline(yintercept = 0, linetype = "dashed", colour = "grey50") +
    geom_ribbon(aes(ymin = ci90_lo, ymax = ci90_hi), alpha = 0.15,
                fill = "#2166ac") +
    geom_ribbon(aes(ymin = ci68_lo, ymax = ci68_hi), alpha = 0.25,
                fill = "#2166ac") +
    geom_line(aes(y = coef), colour = "#2166ac", linewidth = 0.9) +
    geom_point(aes(y = coef), colour = "#2166ac", size = 2) +
    scale_x_continuous(breaks = 0:H_MAX) +
    labs(
      title    = title_str,
      subtitle = "Jordà (2005) local projections, two-way FE, Driscoll-Kraay SEs",
      x        = "Horizon (years after GERD shock)",
      y        = "Cumulative Δln(GDP per capita)",
      caption  = "Shock: +1pp GERD/GDP. Bands: 68% (dark) and 90% (light) CIs."
    ) +
    theme_pub()

  figs_dir <- file.path(proj_root, "figures")
  dir.create(figs_dir, recursive = TRUE, showWarnings = FALSE)
  ggsave(file.path(figs_dir, filename), p, width = 10, height = 5, dpi = 300)
  cat(sprintf("  Saved: %s\n", filename))
  invisible(p)
}

irf_plot(irf_full,  "IRF: GERD shock → GDP per capita (full N=29)",
         "05_irf_full.png")

# Faceted: close vs catch-up
p_split <- ggplot(irf_all |> filter(label != "Full panel (N=29)"),
                  aes(x = horizon, fill = label, colour = label)) +
  geom_hline(yintercept = 0, linetype = "dashed", colour = "grey50") +
  geom_ribbon(aes(ymin = ci90_lo, ymax = ci90_hi), alpha = 0.12, colour = NA) +
  geom_ribbon(aes(ymin = ci68_lo, ymax = ci68_hi), alpha = 0.22, colour = NA) +
  geom_line(aes(y = coef), linewidth = 0.9) +
  geom_point(aes(y = coef), size = 2) +
  scale_colour_manual(values = c("Close to frontier" = "#2166ac",
                                 "Catch-up (far)"    = "#d6604d"),
                      name = NULL) +
  scale_fill_manual(values  = c("Close to frontier" = "#2166ac",
                                "Catch-up (far)"    = "#d6604d"),
                    name = NULL) +
  scale_x_continuous(breaks = 0:H_MAX) +
  facet_wrap(~ label) +
  labs(
    title    = "IRF by frontier regime: GERD shock → GDP per capita",
    subtitle = "Jordà LP, two-way FE, DK SEs. Split at DTF median.",
    x        = "Horizon (years)", y = "Cumulative Δln(GDP per capita)",
    caption  = "+1pp GERD/GDP shock. Bands: 68% and 90% CIs."
  ) +
  theme_pub() +
  theme(legend.position = "none")

ggsave(file.path(proj_root, "figures", "05_irf_split.png"),
       p_split, width = 12, height = 5, dpi = 300)
cat("  Saved: 05_irf_split.png\n")

# ── Peak effect and significance summary ─────────────────────────────────────
cat("\n═══ LP summary: peak effects ═══\n")
for (lbl in unique(irf_all$label)) {
  sub <- irf_all |> filter(label == lbl)
  peak_row <- sub[which.max(abs(sub$coef)), ]
  sig_h    <- sub |> filter(ci90_lo > 0 | ci90_hi < 0) |> pull(horizon)
  cat(sprintf("  %-24s  peak=%.4f at h=%d  sig at 90%% CI: h=%s\n",
              lbl, peak_row$coef, peak_row$horizon,
              if (length(sig_h)) paste(sig_h, collapse=",") else "none"))
}

# ── Export IRF table ──────────────────────────────────────────────────────────
irf_out <- irf_all |>
  select(label, horizon, coef, se, ci90_lo, ci90_hi, n_obs) |>
  mutate(across(where(is.numeric), \(x) round(x, 5)))

write.csv(irf_out,
          file.path(proj_root, "reports", "05_irf_table.csv"),
          row.names = FALSE)
cat("\nIRF table written to reports/05_irf_table.csv\n")
