# Stage 07 — Heterogeneous Treatment Effects
#
# Two estimators:
#
# 1. Double / Debiased ML  (Chernozhukov et al. 2018, EJ 21(1):C1-C68)
#    Partially linear model:
#      growth_y_{it} = theta * gerd_pct_{it} + g(X_{it}) + alpha_i + lambda_t + e_{it}
#    Protocol:
#      a. Within-transform Y, D, X by country + year FE (FWL step)
#      b. K=5 country-blocked cross-fitting of nuisance E[Y_tilde|X_tilde] and
#         E[D_tilde|X_tilde] using OLS (exact FWL) and ridge (ML debiasing)
#      c. Final stage: OLS of residualised Y on residualised D
#    Comparison: DML-OLS = FWL/FE estimate (sanity check);
#                DML-ridge tests for nonlinear confounding
#
# 2. Causal Forest  (Wager & Athey 2018 JASA; Athey & Wager 2019 AOS)
#    Estimates CATE tau(X) = E[Y(d+1) - Y(d) | X]  (+1pp gerd_pct shock)
#    Panel adaptation (Knaus, Lechner & Strittmatter 2021):
#      Within-transform Y and D before feeding grf::causal_forest()
#    Features X: dtf, ln_krd, tertiary_25_64, savings, n_g_d, year_int
#    Outputs:
#      a. ATE and AIPW estimate
#      b. Variable importance (heterogeneity drivers)
#      c. Best linear projection of CATE (Chernozhukov et al. 2022)
#      d. CATE vs dtf scatter — does frontier distance moderate effect?
#      e. Figure: 07_cate_dtf.png

suppressPackageStartupMessages({
  library(fixest)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(sandwich)
})

# Install grf / glmnet if absent
for (pkg in c("grf", "glmnet")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    install.packages(pkg, repos = "https://cloud.r-project.org", type = "binary")
  }
}
library(grf)
library(glmnet)

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

# ── Load and clean panel ──────────────────────────────────────────────────────
panel_raw <- load_panel(primary_only = TRUE, year_range = c(1998L, 2024L)) |>
  mutate(savings  = savings_pct / 100,
         year_int = as.integer(year))

REQUIRED <- c("growth_y","gerd_pct","dtf","ln_krd","tertiary_25_64",
              "savings","n_g_d","wgi_composite")
panel_clean <- panel_raw |>
  filter(!is.na(growth_y) & !is.na(gerd_pct) & !is.na(dtf) &
         !is.na(ln_krd)   & !is.na(tertiary_25_64) &
         !is.na(savings)  & !is.na(n_g_d)) |>
  arrange(country, year_int)

cat(sprintf("Analysis panel: %d countries x obs=%d\n",
            n_distinct(panel_clean$country), nrow(panel_clean)))

# ── Within-transformation (partial out country + year FE) ─────────────────────
# FWL theorem: within-residuals carry the same theta as feols(...|country+year)
within_resid <- function(var) {
  residuals(
    fixest::feols(as.formula(paste(var, "~ 1 | country + year_int")),
                  data = panel_clean)
  )
}

cat("Within-transforming Y, D, X...\n")
Y <- within_resid("growth_y")
D <- within_resid("gerd_pct")
X_vars <- c("dtf","ln_krd","tertiary_25_64","savings","n_g_d")
X_tilde <- sapply(X_vars, within_resid)   # n x p matrix after FE removal

# FWL sanity check: residualize Y and D against X_tilde globally (no cross-fit)
# then OLS of Y_residual ~ D_residual should match the FE+X coefficient exactly.
fe_check  <- coef(fixest::feols(
  growth_y ~ gerd_pct + dtf + ln_krd + tertiary_25_64 + savings + n_g_d |
    country + year_int,
  data     = panel_clean,
  panel.id = ~ country + year_int,
  vcov     = "DK"))["gerd_pct"]
Y_fwl     <- residuals(lm.fit(X_tilde, Y))
D_fwl     <- residuals(lm.fit(X_tilde, D))
fwl_check <- coef(lm(Y_fwl ~ D_fwl - 1))
cat(sprintf("FE estimate:  %.5f\nFWL check:    %.5f  (should match)\n",
            fe_check, fwl_check))

# ── Double ML: K=5 country-blocked cross-fitting ──────────────────────────────
cat("\n── DML cross-fitting (K=5, country-blocked) ──\n")
countries_vec  <- sort(unique(panel_clean$country))
N_c            <- length(countries_vec)
set.seed(42)
K              <- 5L
country_fold   <- setNames(sample(rep(seq_len(K), length.out = N_c)), countries_vec)
obs_fold       <- country_fold[panel_clean$country]

n <- nrow(panel_clean)
# Separate storage for OLS and ridge residuals — never overwrite Y_tilde_ols
Y_tilde_ols   <- numeric(n)
Y_tilde_ridge <- numeric(n)
D_tilde_ols   <- numeric(n)
D_tilde_ridge <- numeric(n)

for (k in seq_len(K)) {
  tr  <- obs_fold != k
  te  <- obs_fold == k
  Xtr <- X_tilde[tr, , drop = FALSE]
  Xte <- X_tilde[te, , drop = FALSE]

  # OLS nuisance
  Y_tilde_ols[te] <- Y[te] - Xte %*% lm.fit(Xtr, Y[tr])$coefficients
  D_tilde_ols[te] <- D[te] - Xte %*% lm.fit(Xtr, D[tr])$coefficients

  # Ridge nuisance (alpha=0 = ridge; internal 5-fold CV for lambda)
  cv_d <- glmnet::cv.glmnet(Xtr, D[tr], alpha = 0, nfolds = 5)
  cv_y <- glmnet::cv.glmnet(Xtr, Y[tr], alpha = 0, nfolds = 5)
  D_tilde_ridge[te] <- D[te] - predict(cv_d, Xte, s = "lambda.min")[, 1]
  Y_tilde_ridge[te] <- Y[te] - predict(cv_y, Xte, s = "lambda.min")[, 1]
}

dml_reg <- function(y_res, d_res, label) {
  mod <- lm(y_res ~ d_res - 1)
  se  <- sqrt(sandwich::vcovHC(mod, type = "HC3")["d_res", "d_res"])
  b   <- coef(mod)["d_res"]
  cat(sprintf("  %-18s  theta=%.5f  SE=%.5f  t=%.2f  90%%CI [%.5f, %.5f]\n",
              label, b, se, b/se, b - 1.645*se, b + 1.645*se))
  tibble(label = label, theta = b, se = se,
         ci90_lo = b - 1.645*se, ci90_hi = b + 1.645*se)
}

dml_results <- bind_rows(
  dml_reg(Y_tilde_ols,   D_tilde_ols,   "DML-OLS"),
  dml_reg(Y_tilde_ridge, D_tilde_ridge, "DML-Ridge")
)
cat(sprintf("  FE benchmark (DK):  %.5f  (Stage 03 reference)\n", fe_check))

# ── Causal Forest (grf) ───────────────────────────────────────────────────────
cat("\n── Causal Forest ──\n")
# Features for CATE: use raw (not within-transformed) so forest can use
# cross-country variation in X; Y and D are already within-residualized.
X_cf <- panel_clean |>
  select(dtf, ln_krd, tertiary_25_64, savings, n_g_d, year_int) |>
  as.matrix()

# wgi_composite has some NAs; replace with row-mean imputation
if ("wgi_composite" %in% names(panel_clean)) {
  wgi <- panel_clean$wgi_composite
  wgi[is.na(wgi)] <- mean(wgi, na.rm = TRUE)
  X_cf <- cbind(X_cf, wgi_composite = wgi)
}

# Cluster by country for honest calibration and SE computation
clusters_cf <- as.integer(factor(panel_clean$country))

set.seed(42)
cf <- grf::causal_forest(
  X          = X_cf,
  Y          = Y,        # within-residualised growth_y
  W          = D,        # within-residualised gerd_pct
  num.trees  = 3000,
  min.node.size   = 5,
  honesty         = TRUE,
  clusters        = clusters_cf,
  equalize.cluster.weights = TRUE,
  seed = 42
)

# ATE
ate_cf <- grf::average_treatment_effect(cf, target.sample = "all")
cat(sprintf("ATE (forest):  %.5f  SE=%.5f  95%%CI [%.5f, %.5f]\n",
            ate_cf["estimate"], ate_cf["std.err"],
            ate_cf["estimate"] - 1.96 * ate_cf["std.err"],
            ate_cf["estimate"] + 1.96 * ate_cf["std.err"]))

# Variable importance
vi <- grf::variable_importance(cf)
vi_df <- tibble(feature = colnames(X_cf), importance = vi) |>
  arrange(desc(importance))
cat("\nVariable importance (heterogeneity drivers):\n")
print(vi_df, n = Inf)

# Best linear projection of CATE on X  (Chernozhukov et al. 2022)
cat("\nBest linear projection of CATE on features:\n")
blp <- grf::best_linear_projection(cf, A = X_cf[, c("dtf","ln_krd")])
print(blp)

# ── CATE estimates ────────────────────────────────────────────────────────────
tau_hat <- predict(cf)$predictions

panel_out <- panel_clean |>
  mutate(tau_hat = tau_hat)

cat(sprintf("\nCATE summary: mean=%.5f  SD=%.5f  p10=%.5f  p90=%.5f\n",
            mean(tau_hat), sd(tau_hat),
            quantile(tau_hat, 0.10), quantile(tau_hat, 0.90)))

# ── Figures ───────────────────────────────────────────────────────────────────
figs_dir <- file.path(proj_root, "figures")
dir.create(figs_dir, recursive = TRUE, showWarnings = FALSE)

# CATE vs distance to frontier
p_cate <- ggplot(panel_out, aes(x = dtf, y = tau_hat)) +
  geom_hline(yintercept = 0, linetype = "dashed", colour = "grey50") +
  geom_hline(yintercept = ate_cf["estimate"], linetype = "dotted",
             colour = "#d6604d", linewidth = 0.7) +
  geom_point(aes(colour = tau_hat > 0), alpha = 0.5, size = 1.5) +
  geom_smooth(method = "loess", se = TRUE, span = 0.8,
              colour = "#2166ac", linewidth = 0.9) +
  scale_colour_manual(values = c("TRUE" = "#2166ac", "FALSE" = "#d6604d"),
                      guide = "none") +
  labs(
    title    = "CATE: +1pp GERD effect on growth by frontier distance",
    subtitle = "Causal forest, grf (Wager & Athey 2018). Within-FE residuals.",
    x        = "Distance to frontier (dtf = frontier_ln_y − ln_y_pc)",
    y        = "Estimated CATE tau(X)",
    caption  = "Dotted red line: ATE. Blue loess: conditional mean CATE. N=29 panel 1998-2024."
  ) +
  theme_pub()

ggsave(file.path(figs_dir, "07_cate_dtf.png"), p_cate,
       width = 10, height = 5, dpi = 300)
cat("  Saved: 07_cate_dtf.png\n")

# Variable importance bar chart
p_vi <- ggplot(vi_df, aes(x = reorder(feature, importance), y = importance)) +
  geom_col(fill = "#2166ac", width = 0.7) +
  coord_flip() +
  labs(
    title   = "Causal forest: variable importance for CATE heterogeneity",
    x       = NULL, y = "Importance (fraction of splits)",
    caption = "grf::variable_importance(). Higher = more CATE heterogeneity driven by variable."
  ) +
  theme_pub()

ggsave(file.path(figs_dir, "07_var_importance.png"), p_vi,
       width = 9, height = 5, dpi = 300)
cat("  Saved: 07_var_importance.png\n")

# CATE by country (mean over time)
country_cate <- panel_out |>
  group_by(country) |>
  summarise(mean_tau = mean(tau_hat), mean_dtf = mean(dtf), .groups = "drop")

p_country <- ggplot(country_cate,
                    aes(x = reorder(country, mean_tau), y = mean_tau,
                        fill = mean_tau > 0)) +
  geom_col(width = 0.7) +
  geom_hline(yintercept = 0, linewidth = 0.4) +
  geom_hline(yintercept = ate_cf["estimate"], linetype = "dashed",
             colour = "#d6604d", linewidth = 0.7) +
  scale_fill_manual(values = c("TRUE" = "#2166ac", "FALSE" = "#d6604d"),
                    guide = "none") +
  coord_flip() +
  labs(
    title   = "Country-mean CATE: GERD effect heterogeneity across economies",
    subtitle = "Causal forest. Dashed = ATE.",
    x = NULL, y = "Mean CATE tau(X)",
    caption = "Within-FE residuals. grf (Wager & Athey 2018)."
  ) +
  theme_pub()

ggsave(file.path(figs_dir, "07_country_cate.png"), p_country,
       width = 10, height = 7, dpi = 300)
cat("  Saved: 07_country_cate.png\n")

# ── Export DML + ATE summary ──────────────────────────────────────────────────
ate_row <- tibble(
  label   = "Causal Forest ATE",
  theta   = ate_cf["estimate"],
  se      = ate_cf["std.err"],
  ci90_lo = ate_cf["estimate"] - 1.645 * ate_cf["std.err"],
  ci90_hi = ate_cf["estimate"] + 1.645 * ate_cf["std.err"]
)
fe_row <- tibble(label = "FE (DK) Stage03",
                 theta = fe_check, se = NA_real_,
                 ci90_lo = NA_real_, ci90_hi = NA_real_)

stage07_tbl <- bind_rows(dml_results, ate_row, fe_row) |>
  mutate(across(where(is.numeric), \(x) round(x, 5)))

write.csv(stage07_tbl,
          file.path(proj_root, "reports", "07_hte_summary.csv"),
          row.names = FALSE)

write.csv(panel_out |>
            select(country, year_int, dtf, ln_krd, tau_hat) |>
            mutate(tau_hat = round(tau_hat, 6)),
          file.path(proj_root, "reports", "07_cate_panel.csv"),
          row.names = FALSE)

cat("\nHTE summary written to reports/07_hte_summary.csv\n")
cat("CATE panel written to  reports/07_cate_panel.csv\n")

# ── Final summary ─────────────────────────────────────────────────────────────
cat("\n═══ Stage 07 summary ═══\n")
cat(sprintf("  DML-OLS  theta = %.5f  (FE=%.5f; differs due to K-fold country blocking)\n",
            dml_results$theta[1], fe_check))
cat(sprintf("  DML-Ridge theta = %.5f\n", dml_results$theta[2]))
cat(sprintf("  CF ATE   theta = %.5f  SE=%.5f\n",
            ate_cf["estimate"], ate_cf["std.err"]))
cat(sprintf("  CATE SD  = %.5f  (treatment effect heterogeneity)\n", sd(tau_hat)))
top_vi <- vi_df$feature[1]
cat(sprintf("  Top CATE driver: %s (importance=%.3f)\n",
            top_vi, vi_df$importance[1]))
