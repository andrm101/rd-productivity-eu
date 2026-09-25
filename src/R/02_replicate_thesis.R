# Stage 02 — Faithful replication of thesis FE/RE estimates
# Target coefficients: GERD: −0.0255, SAVINGS: +0.2173, N_G_D: +0.0689
# Tolerance: ±0.005 on coefficients, ±0.02 on R², ±0.5 on Hausman χ²

suppressPackageStartupMessages({
  library(plm)
  library(fixest)
  library(modelsummary)
  library(ggplot2)
  library(dplyr)
  library(tidyr)
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

# ── Country set matching the original 25 ──────────────────────────────────────
THESIS_25 <- c(
  "AT","BE","BG","CY","CZ","DE","DK","EE","ES","FI","FR","GR","HR","HU",
  "IT","LT","LU","LV","MT","NL","PL","PT","RO","SE","SK"
)

# ── Load panel, restrict to thesis scope ─────────────────────────────────────
panel <- load_panel(primary_only = FALSE, year_range = c(1998L, 2023L)) |>
  filter(country %in% THESIS_25)

# Replicate thesis variable names (first-differenced GDP_CAP used as outcome;
# IDEAS_CAP ≈ pat_pct; HUMAN_CAP ≈ tertiary_25_64)
#
# Scale notes (diagnosed in Stage 02):
#   savings_pct is stored as percent (range 5–37); the thesis used decimal
#   proportion (divide by 100) — confirmed by 100× coefficient discrepancy.
#   n_g_d is stored in decimal form; thesis may have used log(n+g+delta) per
#   the MRW theoretical specification. We replicate both variants below.
panel <- panel |>
  rename_with(~ "ideas_cap",   .cols = any_of("pat_pct")) |>
  rename_with(~ "human_cap",   .cols = any_of("tertiary_25_64")) |>
  rename_with(~ "gerd",        .cols = any_of("gerd_pct")) |>
  mutate(
    diff_gdp_cap = growth_y,          # growth_y = Δln_y_pc (Stage 01)
    savings      = savings_pct / 100, # rescale to [0,1] to match thesis
    ln_n_g_d     = log(n_g_d)         # MRW theoretical form: ln(n+g+delta)
  )

pd <- plm::pdata.frame(panel, index = c("country", "year"))

# ── FE and RE models — thesis specification ───────────────────────────────────
# Spec A: levels for n_g_d (as stored in panel)
thesis_formula <- diff_gdp_cap ~ gerd + ideas_cap + savings + human_cap + n_g_d
# Spec B: log(n_g_d) per MRW theoretical derivation
thesis_formula_log <- diff_gdp_cap ~ gerd + ideas_cap + savings + human_cap + ln_n_g_d

m_fe    <- plm::plm(thesis_formula,     data = pd, model = "within")
m_re    <- plm::plm(thesis_formula,     data = pd, model = "random")
m_fe_ln <- plm::plm(thesis_formula_log, data = pd, model = "within")

# Hausman test
haus <- plm::phtest(m_fe, m_re)
cat("\n── Hausman test (Spec A: n_g_d levels) ──\n")
print(haus)
cat("Expected: chi2 ≈ 9.15, p ≈ 0.10\n")

cat("\n── Spec B coefficients (ln_n_g_d) ──\n")
print(summary(m_fe_ln)$coefficients)

# ── Replication tolerance check ───────────────────────────────────────────────
# Primary comparison uses Spec A (savings rescaled to [0,1])
target <- c(gerd = -0.0255, savings = 0.2173, n_g_d = 0.0689)
achieved <- coef(m_fe)[names(target)]
deltas   <- abs(achieved - target)

cat("\n── Coefficient replication (Spec A: savings/100, n_g_d levels) ──\n")
for (nm in names(target)) {
  flag <- if (deltas[nm] <= 0.005) "PASS" else "FAIL"
  cat(sprintf("  %-12s  target: %+.4f  got: %+.4f  delta: %.4f  [%s]\n",
              nm, target[nm], achieved[nm], deltas[nm], flag))
}

# ── Extended diagnostics (thesis omitted these) ───────────────────────────────

# 1. Pesaran CD test (cross-sectional dependence)
if (requireNamespace("plm", quietly = TRUE)) {
  cd <- tryCatch(plm::pcdtest(m_fe, test = "cd"), error = function(e) NULL)
  if (!is.null(cd)) {
    cat("\n── Pesaran CD test (cross-sectional dependence) ──\n"); print(cd)
  }
}

# 2. Wooldridge serial correlation test
wtest <- tryCatch(plm::pbgtest(m_fe), error = function(e) NULL)
if (!is.null(wtest)) {
  cat("\n── Wooldridge/Breusch-Godfrey serial correlation ──\n"); print(wtest)
}

# 3. Breusch-Pagan LM for RE vs pooled
bp <- tryCatch(plm::plmtest(m_re, type = "bp"), error = function(e) NULL)
if (!is.null(bp)) {
  cat("\n── Breusch-Pagan LM (RE vs pooled) ──\n"); print(bp)
}

# 4. Driscoll-Kraay SE (robust to CD + serial dependence) via fixest
#    panel.id required for DK VCOV; year must be numeric for bandwidth selection
m_fe_dk <- fixest::feols(
  diff_gdp_cap ~ gerd + ideas_cap + savings + human_cap + n_g_d | country + year,
  data     = panel |> mutate(year = as.integer(year)),
  panel.id = ~ country + year,
  vcov     = "DK"
)
cat("\n── FE with Driscoll-Kraay SEs ──\n")
fixest::etable(m_fe_dk)

# ── Modelsummary output ───────────────────────────────────────────────────────
report_path <- file.path(proj_root, "reports", "02_replication.md")
dir.create(dirname(report_path), recursive = TRUE, showWarnings = FALSE)

modelsummary::modelsummary(
  list("FE (plm)" = m_fe, "RE (plm)" = m_re,
       "FE ln(n+g+d)" = m_fe_ln, "FE Driscoll-Kraay" = m_fe_dk),
  stars       = TRUE,
  output      = report_path,
  title       = "Stage 02 — Thesis Replication (N=25, 1998–2023)",
  notes       = paste("Thesis targets: GERD=−0.0255, SAVINGS=+0.2173, N_G_D=+0.0689.",
                      "Tolerance ±0.005 on coefficients.")
)
cat("\nReplication table written to", report_path, "\n")

# ── Spaghetti plots ───────────────────────────────────────────────────────────
figs_dir <- file.path(proj_root, "figures")
dir.create(figs_dir, recursive = TRUE, showWarnings = FALSE)

# Colour by region (proxy: innovator countries = Nordic + Western)
innovators <- c("SE","FI","DK","DE","AT","NL","BE","FR","LU")
panel$cluster_label <- ifelse(panel$country %in% innovators, "Innovator (Cluster 1)", "Catch-up (Cluster 2)")

p_gdp <- ggplot(panel |> filter(!is.na(ln_y_pc)),
                aes(year, ln_y_pc, group = country, colour = cluster_label)) +
  geom_line(alpha = 0.7, linewidth = 0.5) +
  scale_colour_manual(values = c("Innovator (Cluster 1)" = "#2166ac",
                                 "Catch-up (Cluster 2)"  = "#d6604d"),
                      name = NULL) +
  labs(title = "ln(GDP per capita, PPS) — N=25 thesis panel, 1998–2023",
       x = NULL, y = "ln(GDP per capita)",
       caption = "Source: Eurostat nama_10_pc. Two-cluster colouring is illustrative (Stage 05).") +
  theme_pub()

ggsave(file.path(figs_dir, "02_panel_spaghetti.png"), p_gdp,
       width = 12, height = 6, dpi = 300)
cat("Spaghetti plot saved.\n")

# Diagnostics summary
diag_path <- file.path(proj_root, "reports", "02_diagnostics.md")
sink(diag_path)
cat("# Stage 02 — Diagnostic Battery\n\n")
cat("## Hausman Test\n```\n"); print(haus); cat("```\n\n")
if (!is.null(cd))    { cat("## Pesaran CD Test\n```\n");          print(cd);    cat("```\n\n") }
if (!is.null(wtest)) { cat("## Serial Correlation (BG)\n```\n");  print(wtest); cat("```\n\n") }
if (!is.null(bp))    { cat("## Breusch-Pagan LM\n```\n");         print(bp);    cat("```\n\n") }
sink()
cat("Diagnostics written to", diag_path, "\n")
