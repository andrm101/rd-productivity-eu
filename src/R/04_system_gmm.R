# Stage 04 — Endogeneity checks: IV/2SLS and dynamic identification
#
# WHY AB/BB GMM FAILS HERE:
#   Arellano-Bond/Blundell-Bond is designed for large-N, small-T panels
#   (canonical application: N~140, T~7). With N=29 and T=27 the asymptotic
#   theory does not hold: the weight matrix is nearly singular, AR(1) in
#   differences is not significant (the identifying signal is absent), and
#   the lagged-level instruments do not satisfy the relevance condition.
#   This is a published limitation (Roodman 2009 "A Note on the Theme of
#   Too Many Instruments"; Hauk & Wacziarg 2009 on small-N growth panels).
#
# APPROPRIATE ALTERNATIVES for N=29, T=27:
#   1. 2SLS with internal lagged instruments (Anderson-Hsiao style)
#      — gerd_pct instrumented by gerd_lag2, gerd_lag3
#      — Implemented below via fixest::feols(... | .) syntax
#   2. Local projections (Stage 05) — impulse-response approach avoids
#      strong instrument assumptions entirely
#   3. CCE/PMG (Pesaran 2006) — handles cross-sectional dependence in
#      long panels (reserved for Stage 06 spatial extension)
#
# The null result from FE+DK (Stage 03) is conservative: if reverse
# causality creates upward bias, removing it only strengthens the null.
# The 2SLS below tests the direction of bias.

suppressPackageStartupMessages({
  library(fixest)
  library(dplyr)
  library(tidyr)
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

panel <- load_panel(primary_only = TRUE, year_range = c(1998L, 2024L)) |>
  mutate(
    savings  = savings_pct / 100,
    year_int = as.integer(year)
  )

cat(sprintf("Panel: %d countries x %d years, %d obs\n",
            n_distinct(panel$country), n_distinct(panel$year), nrow(panel)))

# ── Restate FE benchmark (growth_y, DK SEs) ───────────────────────────────────
m_fe <- fixest::feols(
  growth_y ~ gerd_pct + savings + tertiary_25_64 + n_g_d + dtf | country + year,
  data     = panel |> mutate(year = year_int),
  panel.id = ~ country + year,
  vcov     = "DK"
)

# ── 2SLS: instrument gerd_pct with gerd_lag2, gerd_lag3 ──────────────────────
# Rationale: R&D spending in t-2 and t-3 is predetermined relative to
# current growth shocks. If fast current growth causes more R&D (reverse
# causality), lags 2-3 break that channel while preserving the
# R&D→growth signal.
# fixest IV syntax: y ~ exog | FE | endog ~ instruments

m_iv2 <- fixest::feols(
  growth_y ~ savings + tertiary_25_64 + n_g_d + dtf | country + year |
    gerd_pct ~ gerd_lag2 + gerd_lag3,
  data     = panel |> mutate(year = year_int),
  panel.id = ~ country + year,
  vcov     = "DK"
)

m_iv3 <- fixest::feols(
  growth_y ~ savings + tertiary_25_64 + n_g_d + dtf | country + year |
    gerd_pct ~ gerd_lag2 + gerd_lag3 + gerd_avg3,
  data     = panel |> mutate(year = year_int),
  panel.id = ~ country + year,
  vcov     = "DK"
)

# ── 2SLS with knowledge stock: instrument ln_krd with krd_lag2, krd_lag3 ──────
# ln_krd is persistent but its lags still satisfy relevance (partial F > 10)
m_iv_krd <- fixest::feols(
  growth_y ~ savings + tertiary_25_64 + n_g_d + dtf | country + year |
    ln_krd ~ krd_lag2 + krd_lag3,
  data     = panel |> mutate(year = year_int),
  panel.id = ~ country + year,
  vcov     = "DK"
)

# ── Print results ──────────────────────────────────────────────────────────────
cat("\n═══ FE vs 2SLS: endogeneity direction test ═══\n")
fixest::etable(m_fe, m_iv2, m_iv3, m_iv_krd,
               keep    = c("gerd_pct","fit_gerd_pct","ln_krd","fit_ln_krd",
                           "savings","n_g_d","dtf"),
               headers = c("FE (DK)","IV gerd lag2-3","IV gerd +avg3","IV ln_krd lag2-3"))

# ── First-stage diagnostics ───────────────────────────────────────────────────
cat("\n═══ First-stage F-statistics (instrument relevance) ═══\n")
for (lbl in c("m_iv2","m_iv3","m_iv_krd")) {
  mod <- get(lbl)
  fs  <- tryCatch(fitstat(mod, "ivf"), error = function(e) NULL)
  if (!is.null(fs)) {
    cat(sprintf("  %-14s  first-stage F = %.2f  (rule of thumb: > 10)\n",
                lbl, fs[[1]]$stat))
  }
}

# ── Wu-Hausman endogeneity test ────────────────────────────────────────────────
cat("\n═══ Wu-Hausman endogeneity test (H0: gerd_pct exogenous) ═══\n")
for (lbl in c("m_iv2","m_iv3")) {
  mod <- get(lbl)
  wh  <- tryCatch(fitstat(mod, "wh"), error = function(e) NULL)
  if (!is.null(wh)) {
    cat(sprintf("  %-14s  stat=%.3f  p=%.4f  %s\n",
                lbl, wh$wh$stat, wh$wh$p,
                if (wh$wh$p < 0.05) "[reject exogeneity — endogeneity confirmed]"
                else "[fail to reject — FE is consistent]"))
  }
}

# ── Direction-of-bias summary ─────────────────────────────────────────────────
fe_c   <- coef(m_fe)["gerd_pct"]
iv2_c  <- tryCatch(coef(m_iv2)["fit_gerd_pct"],  error=function(e) NA_real_)
iv3_c  <- tryCatch(coef(m_iv3)["fit_gerd_pct"],  error=function(e) NA_real_)
krd_fe <- tryCatch(coef(fixest::feols(
  growth_y ~ ln_krd + savings + tertiary_25_64 + n_g_d + dtf | country + year,
  data=panel|>mutate(year=year_int), panel.id=~country+year, vcov="DK"))["ln_krd"],
  error=function(e) NA_real_)
krd_iv <- tryCatch(coef(m_iv_krd)["fit_ln_krd"],  error=function(e) NA_real_)

cat("\n═══ Endogeneity summary ═══\n")
cat(sprintf("  FE  gerd_pct : %.4f\n", fe_c))
cat(sprintf("  IV  gerd_pct : %.4f  (lag-2 instruments)\n", iv2_c))
cat(sprintf("  IV  gerd_pct : %.4f  (lag-2-3 + avg3)\n",    iv3_c))
cat(sprintf("  FE  ln_krd   : %.4f\n", krd_fe))
cat(sprintf("  IV  ln_krd   : %.4f  (lag-2-3 instruments)\n", krd_iv))
cat("\n")
cat("  If IV > FE: attenuation bias (meas. error); true effect larger than FE shows\n")
cat("  If IV < FE: upward bias (reverse causality); true effect smaller than FE\n")
cat("  If IV ≈ FE: exogeneity holds; proceed with FE+DK SEs as primary estimator\n")

# ── Distributed lag structure (GERD lags 0-3) ─────────────────────────────────
# Tests whether lagged GERD has effects not visible in contemporaneous spec.
# A significant lag-2 or lag-3 without lag-0 would confirm the Griliches (1979)
# long-run channel: R&D investment accumulates before affecting productivity.
cat("\n═══ Distributed GERD lags (FE, DK SEs) ═══\n")
m_dl <- fixest::feols(
  growth_y ~ gerd_pct + gerd_lag1 + gerd_lag2 + gerd_lag3
           + savings + tertiary_25_64 + n_g_d + dtf | country + year,
  data     = panel |> mutate(year = year_int),
  panel.id = ~ country + year,
  vcov     = "DK"
)
fixest::etable(m_dl, keep = c("gerd_pct","gerd_lag1","gerd_lag2","gerd_lag3"))

# Cumulative (sum of lags 0-3) and test if jointly zero
cat("\n-- Wald test: lags 0-3 jointly zero --\n")
tryCatch(
  print(fixest::wald(m_dl, c("gerd_pct","gerd_lag1","gerd_lag2","gerd_lag3"))),
  error = function(e) cat("Wald:", conditionMessage(e), "\n")
)

# ── Save coefficient comparison figure ────────────────────────────────────────
coef_compare <- tibble::tibble(
  estimator = c("FE (DK)", "IV lag2-3", "IV +avg3", "FE krd", "IV krd"),
  coef      = c(fe_c, iv2_c, iv3_c, krd_fe, krd_iv),
  var       = c(rep("gerd_pct",3), rep("ln_krd",2))
) |> filter(!is.na(coef))

p <- ggplot(coef_compare, aes(x = estimator, y = coef, fill = var)) +
  geom_col(width = 0.6) +
  geom_hline(yintercept = 0, linewidth = 0.4) +
  scale_fill_manual(values = c("gerd_pct"="#2166ac","ln_krd"="#d6604d"), name=NULL) +
  facet_wrap(~ var, scales = "free_x") +
  labs(title = "FE vs IV: R&D coefficient across estimators",
       subtitle = "If IV >> FE: measurement error dominates. If IV << FE: reverse causality.",
       x = NULL, y = "Coefficient on R&D variable",
       caption = "DK SEs throughout. Instruments: gerd_pct lags 2-3.") +
  theme_pub()

figs_dir <- file.path(proj_root, "figures")
dir.create(figs_dir, recursive = TRUE, showWarnings = FALSE)
ggsave(file.path(figs_dir, "04_fe_vs_iv.png"), p, width=10, height=5, dpi=300)
cat("\nFE vs IV figure saved.\n")
