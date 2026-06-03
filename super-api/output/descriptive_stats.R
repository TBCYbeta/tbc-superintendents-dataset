rm(list = ls())

library(readxl)
library(dplyr)
library(tidyr)
library(stringr)
library(ggplot2)
library(scales)
library(gender)
library(knitr)
library(kableExtra)

setwd("/Users/camerongreene/Dropbox (Personal)/2. Seth/super-api")

dir.create("output/figures", recursive = TRUE, showWarnings = FALSE)

# A superintendent record is "named" if it is not NA and not a missing-value code
is_named <- function(x) !is.na(x) & !(trimws(as.character(x)) %in% c("", "UNKNOWN", "NA", "N/A"))

################################################################################
# Load data
################################################################################

df <- read_excel("superintendents_2025-2026_processed.xlsx")

named <- df %>% filter(is_named(superintendent))

################################################################################
# Name cleaning
################################################################################

named <- named %>%
  mutate(name_clean = superintendent) %>%
  mutate(name_clean = iconv(name_clean, to = "ASCII//TRANSLIT")) %>%
  mutate(name_clean = str_replace_all(name_clean, '[^\\w\\s\\-\\.]', '')) %>%
  mutate(name_clean = str_squish(name_clean))

todrop <- c("dr", "jr", "sr", "ed\\.?d\\.?", "ph\\.?d\\.?", "phd", "ii", "iii", "iv", "interim")
for (pattern in todrop) {
  named <- named %>%
    mutate(
      name_clean = str_remove_all(name_clean, regex(paste0("\\b", pattern, "\\b"), ignore_case = TRUE)),
      name_clean = str_squish(name_clean)
    )
}

named <- named %>%
  mutate(
    first_name = word(name_clean, 1),
    surname    = word(name_clean, -1)
  ) %>%
  filter(!is.na(first_name), first_name != "", !is.na(surname), surname != "")

################################################################################
# Gender prediction
################################################################################

gender_res <- gender(unique(named$first_name), method = "ssa")

named <- named %>%
  left_join(gender_res %>% select(name, gender, proportion_male, proportion_female),
            by = c("first_name" = "name"))

cat("Gender breakdown:\n")
print(table(named$gender, useNA = "ifany"))
cat(sprintf("Proportion male (classified): %.1f%%\n",
            mean(named$gender == "male", na.rm = TRUE) * 100))

################################################################################
# Figure 1: Superintendent identification rate by state (enrollment-weighted)
################################################################################

elsi <- read.csv("archive/ELSI_csv_export_6391199219081452341930.csv", skip = 6)
colnames(elsi) <- c("agency_name", "state_name", "nces_id", "supervisory_union",
                    "agency_type", "total_students")
elsi$total_students <- as.numeric(trimws(elsi$total_students))
elsi$nces_id <- trimws(elsi$nces_id)

df$leaid_str <- str_pad(as.character(as.integer(df$LEAID)), 7, pad = "0")
elsi$nces_id_str <- str_pad(trimws(elsi$nces_id), 7, pad = "0")

merged <- df %>%
  left_join(elsi %>% select(nces_id_str, total_students),
            by = c("leaid_str" = "nces_id_str"))

state_coverage <- merged %>%
  mutate(state_title = str_to_title(district_state),
         state_title = str_replace_all(state_title, "U\\.s\\.", "U.S.")) %>%
  group_by(state_title) %>%
  summarise(
    total_districts      = n(),
    named_districts      = sum(is_named(superintendent)),
    high_cert            = sum(certainty == "high", na.rm = TRUE),
    total_enrollment     = sum(total_students, na.rm = TRUE),
    named_enrollment     = sum(total_students[is_named(superintendent)], na.rm = TRUE),
    high_cert_enrollment = sum(total_students[certainty == "high" & !is.na(certainty)], na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    pct_named        = named_districts / total_districts * 100,
    pct_high         = high_cert / total_districts * 100,
    pct_enroll_named = named_enrollment / total_enrollment * 100,
    pct_enroll_high  = high_cert_enrollment / total_enrollment * 100
  )

fig1 <- ggplot(state_coverage %>% filter(total_districts >= 10),
               aes(x = reorder(state_title, pct_enroll_high), y = pct_enroll_named)) +
  geom_col(fill = "steelblue", alpha = 0.8) +
  geom_col(aes(y = pct_enroll_high), fill = "darkblue", alpha = 0.6) +
  coord_flip() +
  scale_y_continuous(limits = c(0, 100), labels = function(x) paste0(x, "%")) +
  labs(
    title = "Superintendent Identification Rate by State (Enrollment-Weighted)",
    subtitle = "Dark blue = high-certainty; light blue = any named identification. 2025–2026.",
    x = NULL,
    y = "Share of enrollment (%)",
    caption = "States with fewer than 10 districts excluded. Weighted by NCES ELSI 2024–25 enrollment."
  ) +
  theme_minimal() +
  theme(
    axis.text.y  = element_text(size = 7),
    plot.title   = element_text(face = "bold"),
    panel.grid.major.y = element_blank()
  )

ggsave("output/figures/fig1_coverage_by_state.png",
       plot = fig1, width = 8, height = 12, dpi = 300, bg = "white")

################################################################################
# Table 1: Coverage + demographics by state
################################################################################

coverage_table <- state_coverage %>%
  arrange(state_title) %>%
  select(
    State                    = state_title,
    `Total districts`        = total_districts,
    `Named (%)`              = pct_named,
    `High certainty (%)`     = pct_high,
    `Enrollment covered (%)` = pct_enroll_named
  ) %>%
  mutate(
    `Named (%)`              = round(`Named (%)`, 1),
    `High certainty (%)`     = round(`High certainty (%)`, 1),
    `Enrollment covered (%)` = round(`Enrollment covered (%)`, 1)
  )

us_row <- tibble(
  State                    = "TOTAL",
  `Total districts`        = nrow(df),
  `Named (%)`              = round(mean(is_named(df$superintendent)) * 100, 1),
  `High certainty (%)`     = round(mean(df$certainty == "high", na.rm = TRUE) * 100, 1),
  `Enrollment covered (%)`  = round(
    sum(merged$total_students[is_named(merged$superintendent)], na.rm = TRUE) /
    sum(merged$total_students, na.rm = TRUE) * 100, 1)
)

coverage_table_full <- bind_rows(coverage_table, us_row)

combined_display <- coverage_table_full %>%
  rename(
    State                   = State,
    `Named (\\%)`           = `Named (%)`,
    `High cert. (\\%)`      = `High certainty (%)`,
    `Enroll. covered (\\%)` = `Enrollment covered (%)`
  )

kable(combined_display,
      format    = "latex",
      booktabs  = TRUE,
      longtable = TRUE,
      digits    = 1,
      align     = c("l", "r", "r", "r", "r"),
      escape    = FALSE,
      caption   = "District Identification Rates by State, 2025--2026",
      label     = "combined") %>%
  kable_styling(latex_options = c("repeat_header"), font_size = 9) %>%
  writeLines("output/figures/table1_combined.tex")

################################################################################
# Table 2: Gender comparison to Superintendent Lab
################################################################################

# pct_male in the xlsx is an Excel formula (=100-B*); read pct_female and derive pct_male in R
suplab <- read_xlsx("output/figures/suplab_2025_gender.xlsx") %>%
  mutate(
    pct_female_num  = suppressWarnings(as.numeric(pct_female)),
    pct_male_suplab = ifelse(!is.na(pct_female_num), round(100 - pct_female_num, 1), NA_real_)
  ) %>%
  select(state, pct_male_suplab)

# Map state names to abbreviations using R built-ins + DC
state_lookup <- data.frame(
  state_name = c(state.name, "District Of Columbia"),
  state_abb  = c(state.abb,  "DC"),
  stringsAsFactors = FALSE
)

our_by_state <- named %>%
  mutate(state_title = str_to_title(district_state)) %>%
  left_join(state_lookup, by = c("state_title" = "state_name")) %>%
  filter(!is.na(state_abb)) %>%
  group_by(state_abb) %>%
  summarise(
    pct_male_ours = round(mean(gender == "male", na.rm = TRUE) * 100, 1),
    .groups = "drop"
  )

our_total_pct <- round(mean(named$gender == "male", na.rm = TRUE) * 100, 1)

gender_comparison <- suplab %>%
  rename(state_abb = state) %>%
  left_join(our_by_state, by = "state_abb") %>%
  arrange(state_abb) %>%
  bind_rows(
    tibble(state_abb = "TOTAL", pct_male_suplab = 74.1, pct_male_ours = our_total_pct)
  ) %>%
  mutate(
    pct_male_suplab_disp = ifelse(is.na(pct_male_suplab), "--", as.character(pct_male_suplab)),
    pct_male_ours_disp   = ifelse(is.na(pct_male_ours),   "--", as.character(pct_male_ours))
  )

gender_display <- gender_comparison %>%
  select(
    State                  = state_abb,
    `Our Data (2025--26)`  = pct_male_ours_disp,
    `Sup.\\ Lab (2024--25)` = pct_male_suplab_disp
  )

kable(gender_display,
      format    = "latex",
      booktabs  = TRUE,
      longtable = TRUE,
      align     = c("l", "r", "r"),
      escape    = FALSE,
      caption   = "Share of male superintendents (\\%): comparison to \\citet{superintendentlab}",
      label     = "gender_comparison") %>%
  kable_styling(latex_options = c("repeat_header"), font_size = 9) %>%
  writeLines("output/figures/table2_gender_comparison.tex")

cat("\nDone. Outputs written to output/figures/\n")
cat("  Figure: fig1_coverage_by_state.png (enrollment-weighted, ranked by high-certainty)\n")
cat("  Tables: table1_combined.tex, table2_gender_comparison.tex\n")
