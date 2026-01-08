# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

setwd(here())
getwd()

################################################################################
# Load superintendent and CCD data 
# ccd_all contains all ccd observations 
# ccd contains regular public schools only and k-12 districts only 
################################################################################
# load all supers 
load(file.path("data", "processed", "combined_superintendents.Rda"))

# load all CCD data 
for (year in 1990:2024) {
  load(file.path("data", "raw", "urban_inst", paste0("chars_", year, ".Rda")))
}

# Start with the first year
load(file.path("data", "raw", "urban_inst", "chars_1990.Rda"))
ccd <- chars_1990 %>% 
  select(state_mailing, leaid, lea_name, city_mailing, enrollment, year, agency_type, highest_grade_offered)

ccd <- ccd %>%
  mutate(
    agency_type = as.character(agency_type),
    highest_grade_offered = as.character(highest_grade_offered),
    leaid = as.character(leaid)
  )

# Loop through remaining years and select same variables
for (year in 1991:2024) {
  load(file.path("data", "raw", "urban_inst", paste0("chars_", year, ".Rda")))
  
  if (year == 2024) {
    temp_data <- get(paste0("chars_", year)) %>% 
      select(ST, leaid, lea_name, MCITY, enrollment, year, LEA_TYPE, GSHI) %>%
      rename(state_mailing = ST) %>%
      rename(agency_type = LEA_TYPE) %>%
      rename(city_mailing = MCITY) %>%
      rename(highest_grade_offered = GSHI) %>%
      mutate(leaid = as.character(leaid)) 
  } else {
    temp_data <- get(paste0("chars_", year)) %>% 
      select(state_mailing, leaid, lea_name, city_mailing, enrollment, year, agency_type, highest_grade_offered) 
  }
  
  #if (year >= 2022 & year <= 2024) {
    #temp_data <- temp_data %>%
     # mutate(
      #  # Convert agency_type from int to factor with proper labels
       # agency_type = case_when(
        #  agency_type == 1 ~ "Regular local school district",
         # TRUE ~ as.character(agency_type)
        #),
        #agency_type = as.factor(agency_type),
        ## Convert highest_grade_offered from int to character
        #highest_grade_offered = as.character(highest_grade_offered)
      #)
  #}
  temp_data <- temp_data %>%
    mutate(
      agency_type = case_when(
        year >= 2022 & year <= 2024 & agency_type == 1 ~ "Regular local school district",
        TRUE ~ as.character(agency_type)
      ),
      highest_grade_offered = as.character(highest_grade_offered)
    )
  temp_data <- temp_data %>%
    mutate(
      agency_type = as.character(agency_type),
      highest_grade_offered = as.character(highest_grade_offered),
      leaid = as.character(leaid)
    )
  ccd <- bind_rows(ccd, temp_data)
}

summary(as.factor(ccd$year))
summary(as.factor(ccd$state_mailing))

# save ccd version with all obs before cleaning further (like dropping non-`regular public school dist')
ccd_all <- ccd

# helper to turn state names or codes into 2-letter lowercase codes
to_state_abbrev <- function(x) {
  u <- toupper(trimws(x))
  map_name_to_abb <- setNames(state.abb, toupper(state.name))
  out <- ifelse(u %in% state.abb, u, map_name_to_abb[u])
  tolower(out)
}

# clean enrollment 
ccd <- ccd %>%
  mutate(enrollment = ifelse(enrollment < 0, NA, enrollment)) %>%
  mutate(state = tolower(state_mailing))

# pad leaid 
ccd <- ccd %>%
  mutate(leaid = ifelse(nchar(leaid) == 6, paste0("0", leaid), leaid))
summary(as.factor(nchar(ccd$leaid)))

# Ensure 1990-1999 are not silently excluded
table(ccd$year)[1:15]                 # should show 1990s present
table(ccd$agency_type, useNA="ifany")
ccd <- ccd %>%
  mutate(
    agency_type = if_else(agency_type %in% c("1", 1),
                          "Regular local school district",
                          as.character(agency_type))
  )
# keep regular districts, open districts, and districts in k-12 
ccd <- ccd %>%
  filter(agency_type == "Regular local school district") %>%
  filter(highest_grade_offered != "Not applicable") %>%
  filter(highest_grade_offered != "-1") %>%
  filter(highest_grade_offered != "-2") %>%
  filter(highest_grade_offered != "NA's") %>%
  filter(highest_grade_offered != "Pre-K") %>%
  filter(highest_grade_offered != "PK") %>%
  filter(highest_grade_offered != "Not applicable") 
table(ccd$year)[1:15]                 # should show 1990s present
table(ccd$agency_type, useNA="ifany")

summary(as.factor(ccd$highest_grade_offered))

# enrollment data check 
ccd_0 <- ccd %>% filter(enrollment==0) 
summary(as.factor(ccd_0$year))

# carryforward enrollment to 2024 (currently no enrollment data for 2024)
ccd <- ccd %>%
  arrange(leaid, year) %>%
  group_by(leaid) %>%
  mutate(enrollment = ifelse(year == 2024, 
                             enrollment[year == 2023][1], 
                             enrollment)) %>%
  ungroup()



################################################################################
# Race and Gender + further name cleaning 
################################################################################

all_supers_clean <- all_supers %>%
  mutate(nwords = str_count(name_clean, "\\S+"))

summary(as.factor(all_supers_clean$nwords))

# additional name cleaning 
todrop <- c("dr", "jr", "ed d", "ph d", "phd", "ii", "iii", "iv", "interim")
for (pattern in todrop) {
  all_supers_clean <- all_supers_clean %>%
    mutate(
      name_clean = str_remove_all(name_clean, regex(paste0("\\b", pattern, "\\b"), ignore_case = TRUE)),
      name_clean = str_trim(name_clean)
    )
}

all_supers_clean <- all_supers_clean %>%
  mutate(
    # Remove all quotation marks and weird characters
    name_clean = str_replace_all(name_clean, '[â""œ]', ''),
    # Clean up extra spaces
    name_clean = str_replace_all(name_clean, "\\s+", " "),
    name_clean = str_squish(name_clean)
  )

all_supers_clean <- all_supers_clean %>%
  mutate(nwords = str_count(name_clean, "\\S+"))

summary(as.factor(all_supers_clean$nwords))


all_supers_clean <- all_supers_clean %>%
  mutate(
    first_name = word(name_clean, 1),
    surname = word(name_clean, -1)
  )

# Get gender predictions
gender_results <- gender(unique(all_supers_clean$first_name))

# Merge gender results
all_supers_clean <- all_supers_clean %>%
  left_join(gender_results, by = c("first_name" = "name"))

# Get race predictions
all_supers_clean <- predict_race(
  voter.file = all_supers_clean,
  surname.only = TRUE
)

# assign race 
all_supers_clean <- all_supers_clean %>%
  rowwise() %>%
  mutate(race = case_when(
    pred.whi == max(c(pred.whi, pred.bla, pred.his, pred.asi, pred.oth), na.rm = TRUE) ~ "white",
    pred.bla == max(c(pred.whi, pred.bla, pred.his, pred.asi, pred.oth), na.rm = TRUE) ~ "black", 
    pred.his == max(c(pred.whi, pred.bla, pred.his, pred.asi, pred.oth), na.rm = TRUE) ~ "hispanic",
    pred.asi == max(c(pred.whi, pred.bla, pred.his, pred.asi, pred.oth), na.rm = TRUE) ~ "asian",
    TRUE ~ "other"  
  )) %>%
  ungroup()

# View results
summary(as.factor(all_supers_clean$race))

head(all_supers_clean %>% 
       select(name_clean, gender, proportion_female, 
              pred.whi, pred.bla, pred.his, pred.asi, pred.oth))


# demographics table 

################################################################################
# Calculate percentages by state
demo_table <- all_supers_clean %>%
  filter(year == 2023) %>%
  group_by(state) %>%
  summarise(
    `Male (%)` = round(mean(gender == "male", na.rm = TRUE) * 100, 1),
    .groups = 'drop'
  ) %>%
  mutate(state = toupper(state))  # Capitalize state abbreviations

unique(demo_table$state)

# Calculate total row
total_row <- all_supers_clean %>%
  filter(year == 2023) %>%
  summarise(
    state = "Total",
    `Male (%)` = round(mean(gender == "male", na.rm = TRUE) * 100, 1),
  )

# Combine with total row
demo_table <- bind_rows(demo_table, total_row)

# Combine with Rachel White (2024-2025) data
demo_table[3] <- read.csv("output/figures/white_demographics_2024_25.csv", header = FALSE)[2]
cor(demo_table[[2]],demo_table[[3]])

# Create matrix for stargazer
demo_matrix <- as.matrix(demo_table[, -1])
rownames(demo_matrix) <- demo_table$state
colnames(demo_matrix) <- c("The Broad Center (2023-24)", "Sup. Lab (2024-25)")

stargazer(demo_matrix,
          type = "latex",
          out = "output/figures/superintendent_demographics.tex",
          title = "",
          summary = FALSE,
          rownames = TRUE,
          align = TRUE,
          digits = 1,  # Changed to 1 decimal place
          no.space = TRUE,
          float = FALSE)

# plot 
# Basic histogram
ggplot(all_supers_clean, aes(x = proportion_male)) +
  geom_histogram(
    bins = 50,
    fill = "#2E86AB",
    color = "white",
    alpha = 0.8
  ) +
  labs(
    title = "Distribution of Variable",
    subtitle = "Histogram showing frequency distribution",
    x = "Variable Name",
    y = "Frequency",
    caption = "Source: Your data source"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 16, face = "bold", hjust = 0.5),
    plot.subtitle = element_text(size = 12, hjust = 0.5, color = "gray60"),
    axis.title = element_text(size = 12),
    axis.text = element_text(size = 10),
    panel.grid.minor = element_blank(),
    plot.caption = element_text(size = 9, color = "gray60")
  )

summary(as.factor(all_supers_clean$gender))

#### 
# Group by state and year, check if any salary entries are non-missing
salary_data_by_state_year <- all_supers_clean %>%
  group_by(state, year) %>%
  summarise(has_salary_data = any(!is.na(salary)), .groups = 'drop') %>%
  filter(has_salary_data == TRUE) %>%
  group_by(state) %>%
  summarise(years_with_data = list(sort(year)), .groups = 'drop')

# Print results for each state
for(i in 1:nrow(salary_data_by_state_year)) {
  state_name <- salary_data_by_state_year$state[i]
  years <- salary_data_by_state_year$years_with_data[[i]]
  
  cat(state_name, ": ", paste(years, collapse = ", "), "\n")
}


################################################################################
# Extension years figure 
################################################################################

# Read the Excel file
data <- read_excel("The Broad Center Data Extension Notes.xlsx", sheet=1)
data <- data %>% mutate(state = State,
                        existing_years = `Years Cleaned`,
                        extension_years = `Extension Years`,
                        salary_years = Salary)  # Add salary column
write.csv(data, "data.csv")

# Function to parse year ranges (e.g., "2010-2015" or "2007-2009, 2016-2025")
parse_years <- function(year_string) {
  if (is.na(year_string) || year_string == "") {
    return(data.frame(start = numeric(0), end = numeric(0)))
  }
  
  # Split by comma and trim whitespace
  ranges <- trimws(strsplit(year_string, ",")[[1]])
  
  # Parse each range or individual year
  years_df <- data.frame(start = numeric(0), end = numeric(0))
  
  for (range in ranges) {
    if (grepl("-", range)) {
      # Handle ranges like "2011-2012"
      parts <- strsplit(range, "-")[[1]]
      start_year <- as.numeric(trimws(parts[1]))
      end_year <- as.numeric(trimws(parts[2]))
      years_df <- rbind(years_df, data.frame(start = start_year, end = end_year))
    } else {
      # Handle individual years like "2008"
      year <- as.numeric(trimws(range))
      if (!is.na(year)) {
        years_df <- rbind(years_df, data.frame(start = year, end = year))
      }
    }
  }
  
  return(years_df)
}

# Process the data to create plotting dataframe with gap filling
plot_data <- data.frame()
salary_data <- data.frame()

for (i in 1:nrow(data)) {
  state <- data$state[i]
  
  # Parse existing years
  existing_years <- parse_years(data$existing_years[i])
  extension_years <- parse_years(data$extension_years[i])
  salary_years <- parse_years(data$salary_years[i])
  
  # Check for gaps and extend years to connect them
  if (nrow(existing_years) > 0 && nrow(extension_years) > 0) {
    # Check all combinations of existing and extension ranges for 1-year gaps
    for (ex_idx in 1:nrow(existing_years)) {
      for (ext_idx in 1:nrow(extension_years)) {
        existing_start <- existing_years$start[ex_idx]
        existing_end <- existing_years$end[ex_idx]
        extension_start <- extension_years$start[ext_idx]
        extension_end <- extension_years$end[ext_idx]
        
        # Case 1: Existing ends, extension starts next year (e.g., existing: 2015-2020, extension: 2021-2025)
        if (extension_start - existing_end == 1) {
          existing_years$end[ex_idx] <- extension_start
        }
        
        # Case 2: Extension ends, existing starts next year (e.g., extension: 2015-2020, existing: 2021-2025)  
        if (existing_start - extension_end == 1) {
          extension_years$end[ext_idx] <- existing_start
        }
      }
    }
  }
  
  # Add existing years to plot data
  if (nrow(existing_years) > 0) {
    existing_years$state <- state
    existing_years$type <- "Existing"
    plot_data <- rbind(plot_data, existing_years)
  }
  
  # Add extension years to plot data
  if (nrow(extension_years) > 0) {
    extension_years$state <- state
    extension_years$type <- "Extension"
    plot_data <- rbind(plot_data, extension_years)
  }
  
  # Add salary years to salary data
  if (nrow(salary_years) > 0) {
    salary_years$state <- state
    salary_data <- rbind(salary_data, salary_years)
  }
}

# Create dummy data for salary legend
salary_legend_data <- data.frame(
  state = "Legend",
  start = 2010,
  end = 2015,
  type = "Salary Data Available"
)

# Create the horizontal bar plot
p <- ggplot(plot_data, aes(y = state)) +
  geom_segment(aes(x = start, xend = end, yend = state, color = type), 
               size = 6, alpha = 0.8) +
  # Add stripes for salary data
  geom_segment(data = salary_data, 
               aes(x = start, xend = end, yend = state), 
               color = "white", 
               size = 1, 
               alpha = 0.9,
               linetype = "dashed") +
  # Add invisible layer for salary legend (won't appear in plot)
  geom_segment(aes(linetype = "Salary Data Available"),
               x = -Inf, xend = -Inf, y = -Inf, yend = -Inf,
               color = "white",
               size = 1,
               alpha = 0) +
  scale_color_manual(values = c("Existing" = "steelblue", "Extension" = "darkblue")) +
  scale_linetype_manual(values = c("Salary Data Available" = "dashed"),
                        guide = guide_legend(override.aes = list(alpha = 1, color = "black", size = 1))) +
  labs(
    title = "",
    x = "Year",
    y = "State",
    color = "",
    linetype = ""
  ) +
  theme_minimal() +
  theme(
    axis.text.y = element_text(size = 10),
    axis.text.x = element_text(size = 10),
    legend.position = "bottom",
    panel.grid.minor.x = element_blank(),
    legend.background = element_rect(fill = "white", color = "white"),
    legend.text = element_text(color = "black"),
    legend.title = element_text(color = "black")
  ) +
  scale_x_continuous(breaks = seq(1990, 2025, by = 2), limits = c(1990, 2025)) +
  scale_y_discrete(limits = rev)

# Display the plot
print(p)

# Save the plot
ggsave(file.path("output/figures", "state_years_plot.png"), plot = p, width = 12, height = 8, dpi = 300, bg = "white")

################################################################################
# Data availability table
################################################################################

# Create indicators for data availability
table1_data <- all_supers %>%
  group_by(state, year) %>%
  summarise(
    has_super_data = n() > 0,
    has_salary_data = any(!is.na(salary)),
    .groups = "drop"
  ) %>%
  mutate(
    indicator = case_when(
      !has_super_data ~ " ",
      has_super_data & has_salary_data ~ "S",
      has_super_data & !has_salary_data ~ "X",
      TRUE ~ " "
    )
  ) %>%
  select(state, year, indicator)

# Get all possible combinations of state and year
all_states <- unique(all_supers$state)
all_years <- unique(all_supers$year)
full_grid <- expand_grid(state = all_states, year = all_years)

# Join with full grid to ensure all combinations are represented
table1_complete <- full_grid %>%
  left_join(table1_data, by = c("state", "year")) %>%
  mutate(indicator = ifelse(is.na(indicator), " ", indicator))

# Pivot to wide format for the table
table1_wide <- table1_complete %>%
  pivot_wider(names_from = year, values_from = indicator, values_fill = " ") %>%
  select(state, sort(as.numeric(names(.)[-1])) %>% as.character())

# Display the table
kable(table1_wide, caption = "Table 1: Data Availability by State and Year")

# Optional: Save as CSV
write.csv(table1_wide, file.path("output/figures", "table1_data_availability.csv"), row.names = FALSE)



################################################################################
# Enrollment coverage 
################################################################################

# Merge ccd and all_supers data
# First prepare the merge keys - ensure consistent format
all_supers_clean <- all_supers_clean %>%
  mutate(
    state = tolower(state),  # ensure lowercase
    leaid = as.character(leaid)  # ensure character
  )

# Create indicator for state-years available in all_supers
available_state_years <- all_supers_clean %>%
  distinct(state, year) %>%
  mutate(state_year_available = TRUE)

# Create indicator for districts with superintendent data
merged_data <- ccd %>%
  left_join(available_state_years, by = c("year", "state")) %>%
  left_join(all_supers_clean, by = c("year", "state", "leaid")) %>%
  mutate(
    has_super_data = !is.na(super_id),  # or use another non-NA column from all_supers
    state_year_available = !is.na(state_year_available)
  )

# Calculate share of students covered by year
coverage_by_year <- merged_data %>%
  group_by(year) %>%
  summarise(
    total_students = sum(enrollment, na.rm = TRUE),
    students_with_super_data = sum(enrollment[has_super_data], na.rm = TRUE),
    # Conditional coverage: only among state-years where superintendent data exists
    total_students_available_states = sum(enrollment[state_year_available], na.rm = TRUE),
    students_with_super_data_available_states = sum(enrollment[has_super_data & state_year_available], na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    coverage_share = students_with_super_data / total_students,
    coverage_percent = coverage_share * 100,
    conditional_coverage_share = students_with_super_data_available_states / total_students_available_states,
    conditional_coverage_percent = conditional_coverage_share * 100
  )

# Prepare data for plotting
coverage_long <- coverage_by_year %>%
  select(year, coverage_percent, conditional_coverage_percent) %>%
  pivot_longer(cols = c(coverage_percent, conditional_coverage_percent),
               names_to = "coverage_type",
               values_to = "percent") %>%
  mutate(
    coverage_type = case_when(
      coverage_type == "coverage_percent" ~ "Overall Coverage",
      coverage_type == "conditional_coverage_percent" ~ "Coverage (Available States Only)"
    )
  )

# Create the bar figure with both coverage measures
p <- ggplot(coverage_long, aes(x = year, y = percent, fill = coverage_type)) +
  geom_col(position = "dodge", alpha = 0.7) +
  scale_fill_manual(values = c("Overall Coverage" = "steelblue", 
                               "Coverage (Available States Only)" = "darkgreen")) +
  scale_y_continuous(labels = scales::percent_format(scale = 1),
                     limits = c(0, 100)) +
  labs(
    title = "Share of Students Covered by Superintendent Data",
    subtitle = "Overall coverage vs. coverage conditional on state-year availability",
    x = "Year",
    y = "Share of Students (%)",
    fill = "Coverage Type",
    caption = "Based on CCD enrollment data and superintendent records"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 14, face = "bold"),
    plot.subtitle = element_text(size = 12),
    axis.text.x = element_text(angle = 45, hjust = 1),
    legend.position = "bottom"
  )

# Display the plot
print(p)

# Save the figure
ggsave(file.path("output/figures", "student_coverage_by_year.png"), 
       plot = p, width = 12, height = 8, dpi = 300, bg = "white")


# Stemper Table 1 

################################################################################
# Filter for 2014 only
ccd_2014 <- ccd %>% filter(year == 2014)
all_supers_2014 <- all_supers_clean %>% filter(year == 2014)

# Create indicators using existing logic
available_states_2014 <- all_supers_2014 %>%
  distinct(state) %>%
  mutate(state_available = TRUE)

# CORRECTED: Use inner join to only keep superintendent records that match CCD districts
# This drops districts in all_supers that don't exist in CCD
valid_supers_2014 <- all_supers_2014 %>%
  inner_join(ccd_2014, by = c("state", "leaid")) %>%
  select(state, leaid, super_id)  # Keep only the superintendent info we need

# Merge data for 2014
merged_2014 <- ccd_2014 %>%
  left_join(available_states_2014, by = "state") %>%
  left_join(valid_supers_2014, by = c("state", "leaid")) %>%
  mutate(
    has_super_data = !is.na(super_id),
    state_available = !is.na(state_available)
  )

# Calculate coverage by state (only for states with superintendent data)
state_coverage <- merged_2014 %>%
  filter(state_available) %>%  # Only states in all_supers
  group_by(state) %>%
  summarise(
    total_enrollment = sum(enrollment, na.rm = TRUE),
    covered_enrollment = sum(enrollment[has_super_data], na.rm = TRUE),
    total_districts = n(),
    covered_districts = sum(has_super_data, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    enrollment_coverage_pct = round((covered_enrollment / total_enrollment) * 100, 1),
    district_coverage_pct = round((covered_districts / total_districts) * 100, 1)
  )

# CORRECTED: Calculate US totals using ALL CCD districts, not just those in available states
us_totals <- merged_2014 %>%
  # Remove the filter(state_available) line to include all states
  summarise(
    state = "US",
    total_enrollment = sum(enrollment, na.rm = TRUE),
    covered_enrollment = sum(enrollment[has_super_data], na.rm = TRUE),
    total_districts = n(),
    covered_districts = sum(has_super_data, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    enrollment_coverage_pct = round((covered_enrollment / total_enrollment) * 100, 1),
    district_coverage_pct = round((covered_districts / total_districts) * 100, 1)
  )

# Combine state and US data
coverage_table <- bind_rows(state_coverage, us_totals) %>%
  select(state, total_enrollment, enrollment_coverage_pct, 
         total_districts, district_coverage_pct)

# Save to Excel
write_xlsx(coverage_table, "output/figures/state_superintendent_coverage_2014.xlsx")

# Debug: Check the differences
print("Debugging - Number of superintendent records before/after CCD matching:")
print(paste("Original all_supers_2014 records:", nrow(all_supers_2014)))
print(paste("Valid supers after CCD matching:", nrow(valid_supers_2014)))
print(paste("Dropped superintendent records:", nrow(all_supers_2014) - nrow(valid_supers_2014)))


# Generate LaTeX table
# Format the table for LaTeX output
coverage_table$state <- toupper(coverage_table$state)
latex_table <- coverage_table %>%
  mutate(
    # Format enrollment with commas
    total_enrollment = format(total_enrollment, big.mark = ",", scientific = FALSE),
    # Add percentage sign to coverage percentages
    enrollment_coverage_pct = paste0(enrollment_coverage_pct, ""),
    district_coverage_pct = paste0(district_coverage_pct, ""),
    # Format district counts with commas
    total_districts = format(total_districts, big.mark = ",", scientific = FALSE)
  ) %>%
  # Rename columns for publication
  rename(
    "State" = state,
    "Total Enrollment" = total_enrollment,
    "Enrollment Coverage (\\%)" = enrollment_coverage_pct,
    "Total Districts" = total_districts,
    "District Coverage (\\%)" = district_coverage_pct
  )

# Also create a version without kableExtra formatting for simpler LaTeX integration
simple_latex <- kable(latex_table, 
                      format = "latex",
                      booktabs = TRUE,
                      escape = FALSE,
                      align = c("c", "c", "c", "c", "c"))

# Write simple LaTeX table to file
writeLines(simple_latex, "output/figures/superintendent_coverage_enrollment_2014.tex")


################################################################################
# Stemper Appendix Fig C1 
################################################################################
# Calculate district counts by state and year
district_counts <- all_supers_clean %>%
  group_by(state, year) %>%
  summarise(district_count = n_distinct(leaid), .groups = "drop") %>%
  mutate(state = toupper(state))  # Convert to uppercase to match figure

# Create a complete grid of all state-year combinations
all_combinations <- expand.grid(
  state = unique(district_counts$state),
  year = min(district_counts$year):max(district_counts$year)
)

# Left join to fill in missing combinations with NA
complete_data <- all_combinations %>%
  left_join(district_counts, by = c("state", "year")) %>%
  mutate(state = factor(state, levels = rev(sort(unique(state)))))

# Create the heatmap
p <- ggplot(complete_data, aes(x = year, y = state, fill = district_count)) +
  geom_tile(color = "white", size = 0.5) +
  geom_text(aes(label = ifelse(is.na(district_count), "", district_count)), 
            color = "black", size = 3, fontface = "bold") +
  scale_fill_gradient(low = "lightgray", high = "lightgray", na.value = "white") +
  scale_x_continuous(breaks = seq(min(complete_data$year), max(complete_data$year), 2)) +
  labs(
    title = "",
    x = "Year",
    y = NULL,
    fill = "District Count"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 14, face = "bold", hjust = 0.5),
    axis.text.x = element_text(angle = 0, hjust = 0.5),
    axis.text.y = element_text(size = 10),
    panel.grid = element_blank(),
    legend.position = "none",  # Remove legend since values are shown in cells
    plot.background = element_rect(fill = "white", color = NA),
    panel.background = element_rect(fill = "white", color = NA)
  ) 

# Display the plot
print(p)

# Save the figure
ggsave("output/figures/district_counts_by_state_year.png", 
       plot = p, width = 12, height = 8, dpi = 300, bg = "white")


################################################################################

# Create balanced panel: only include leaids that appear in every year that the state has data
balanced_panel <- all_supers_clean %>%
  group_by(state) %>%
  mutate(
    # Find the actual years with data for each state (not assuming continuous)
    state_years = list(sort(unique(year))),
    total_years_with_data = n_distinct(year)
  ) %>%
  group_by(state, leaid) %>%
  mutate(
    # Count how many years each leaid appears in for that state
    years_present = n_distinct(year)
  ) %>%
  ungroup() %>%
  group_by(state) %>%
  filter(
    # Only keep leaids that appear in every year that the state has data
    years_present == total_years_with_data
  ) %>%
  ungroup()

# Calculate balanced district counts by state and year
balanced_district_counts <- balanced_panel %>%
  group_by(state, year) %>%
  summarise(district_count = n_distinct(leaid), .groups = "drop") %>%
  mutate(state = toupper(state))  # Convert to uppercase to match figure

# Create a complete grid of all state-year combinations
# Use the full year range from original data, not just balanced panel
all_combinations <- expand.grid(
  state = unique(toupper(all_supers_clean$state)),
  year = min(all_supers_clean$year):max(all_supers_clean$year)
)

# Left join to fill in missing combinations with NA
complete_data_balanced <- all_combinations %>%
  left_join(balanced_district_counts, by = c("state", "year")) %>%
  mutate(state = factor(state, levels = rev(sort(unique(state)))))

# Create the heatmap for balanced panel
p_balanced <- ggplot(complete_data_balanced, aes(x = year, y = reorder(state, state), fill = district_count)) +
  geom_tile(color = "white", size = 0.5) +
  geom_text(aes(label = ifelse(is.na(district_count), "", district_count)), 
            color = "black", size = 3, fontface = "bold") +
  scale_fill_gradient(low = "lightgray", high = "lightgray", na.value = "white") +
  scale_x_continuous(breaks = seq(min(complete_data_balanced$year), max(complete_data_balanced$year), 2)) +
  labs(
    title = "",
    x = "Year",
    y = NULL,
    fill = "District Count"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 14, face = "bold", hjust = 0.5),
    axis.text.x = element_text(angle = 0, hjust = 0.5),
    axis.text.y = element_text(size = 10),
    panel.grid = element_blank(),
    legend.position = "none",  # Remove legend since values are shown in cells
    plot.background = element_rect(fill = "white", color = NA),
    panel.background = element_rect(fill = "white", color = NA)
  ) 

# Display the plot
print(p_balanced)

# Save the figure
ggsave("output/figures/balanced_district_counts_by_state_year.png", 
       plot = p_balanced, width = 12, height = 8, dpi = 300, bg = "white")



################################################################################
# Superintendent turnover
################################################################################
# Calculate superintendent turnover
all_supers_clean$state <- toupper(all_supers_clean$state)
turnover_data <- all_supers_clean %>%
  # Sort by district and year to ensure proper ordering
  arrange(state, leaid, year) %>%
  # Group by district (state + leaid combination)
  group_by(state, leaid) %>%
  # Create lagged super_id and year to compare with previous year
  mutate(
    prev_super_id = lag(super_id, 1),
    prev_year = lag(year, 1),
    # Determine if there was turnover (super_id changed from previous year)
    turnover = case_when(
      is.na(prev_super_id) ~ NA,  # First year of data for district - can't determine turnover
      year != prev_year + 1 ~ NA,  # Gap in years - can't determine turnover
      super_id != prev_super_id ~ TRUE,  # Different superintendent from previous year
      super_id == prev_super_id ~ FALSE  # Same superintendent as previous year
    )
  ) %>%
  ungroup() %>%

  # Remove observations where turnover can't be determined
  filter(!is.na(turnover))

# Calculate turnover rates by state and year
turnover_by_state_year <- turnover_data %>%
  group_by(state, year) %>%
  summarise(
    total_districts = n(),
    turnover_count = sum(turnover),
    turnover_rate = turnover_count / total_districts,
    .groups = "drop"
  ) %>%
  mutate(turnover_percent = round(turnover_rate * 100, 1))

# Calculate overall turnover rates by year
turnover_by_year <- turnover_data %>%
  group_by(year) %>%
  summarise(
    total_districts = n(),
    turnover_count = sum(turnover),
    turnover_rate = turnover_count / total_districts,
    .groups = "drop"
  ) %>%
  mutate(
    state = "OVERALL",
    turnover_percent = round(turnover_rate * 100, 1)
  ) %>%
  select(state, year, total_districts, turnover_count, turnover_rate, turnover_percent)

# Combine state-level and overall data
all_turnover_data <- bind_rows(
  turnover_by_state_year,
  turnover_by_year)

# Create wide format table showing turnover percentages
turnover_table <- all_turnover_data %>%
  select(state, year, turnover_percent) %>%
  pivot_wider(names_from = year, values_from = turnover_percent, values_fill = NA) %>%
  arrange(ifelse(state == "OVERALL", "Z", state))  # Put OVERALL at the bottom

# Display the table
kable(turnover_table,
      caption = "Table: Superintendent Turnover Rate by State and Year (%)",
      digits = 1)

# Create a summary table showing average turnover by state
average_turnover_by_state <- turnover_by_state_year %>%
  group_by(state) %>%
  summarise(
    years_observed = n(),
    total_districts_observed = sum(total_districts),
    total_turnovers = sum(turnover_count),
    average_turnover_rate = mean(turnover_rate),
    .groups = "drop"
  ) %>%
  mutate(average_turnover_percent = round(average_turnover_rate * 100, 1)) %>%
  arrange(desc(average_turnover_percent))

# Display summary table
cat("\nSummary: Average Turnover Rate by State\n")
kable(average_turnover_by_state %>%
        select(state, years_observed, average_turnover_percent),
      caption = "Average Superintendent Turnover Rate by State",
      col.names = c("State", "Years Observed", "Average Turnover (%)"))

# Overall summary statistics
overall_summary <- turnover_by_year %>%
  summarise(
    overall_avg_turnover = mean(turnover_rate),
    min_turnover = min(turnover_rate),
    max_turnover = max(turnover_rate)
  ) %>%
  mutate(across(everything(), ~ round(.x * 100, 1)))

cat("\nOverall Summary Statistics:\n")
cat("Average annual turnover rate:", overall_summary$overall_avg_turnover, "%\n")
cat("Minimum annual turnover rate:", overall_summary$min_turnover, "%\n")
cat("Maximum annual turnover rate:", overall_summary$max_turnover, "%\n")

# Save the main table
write.csv(turnover_table, file.path("output/figures", "superintendent_turnover_table.csv"), row.names = FALSE)

# Create bar plot showing turnover by year and state
# Prepare data for plotting (exclude OVERALL for the faceted plot)
turnover_plot_data <- turnover_by_state_year %>%
  mutate(turnover_percent = round(turnover_rate * 100, 1))

# Create the bar plot with facets by state
p_turnover <- ggplot(turnover_plot_data, aes(x = year, y = turnover_percent)) +
  geom_col(fill = "coral", alpha = 0.7) +
  facet_wrap(~state, scales = "free_y", ncol = 4) +
  scale_y_continuous(labels = scales::percent_format(scale = 1)) +
  labs(
    title = "Superintendent Turnover Rate by State and Year",
    subtitle = "Percentage of districts with superintendent changes from previous year",
    x = "Year",
    y = "Turnover Rate (%)",
    caption = "Based on superintendent records with consecutive year data"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 14, face = "bold"),
    plot.subtitle = element_text(size = 12),
    axis.text.x = element_text(angle = 45, hjust = 1, size = 8),
    strip.text = element_text(size = 10, face = "bold"),
    panel.spacing = unit(0.5, "lines")
  )

# Display the plot
print(p_turnover)

# Save the plot
ggsave(file.path("output/figures", "superintendent_turnover_by_state_year.png"), 
       plot = p_turnover, width = 16, height = 12, dpi = 300, bg = "white")

# Create a second plot showing overall turnover by year
p_overall <- ggplot(turnover_by_year, aes(x = year, y = turnover_percent)) +
  geom_col(fill = "steelblue", alpha = 0.7) +
  scale_y_continuous(labels = scales::percent_format(scale = 1)) +
  labs(
    title = "Overall Superintendent Turnover Rate by Year",
    subtitle = "National average percentage of districts with superintendent changes",
    x = "Year",
    y = "Turnover Rate (%)",
    caption = "Based on superintendent records with consecutive year data"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(size = 14, face = "bold"),
    plot.subtitle = element_text(size = 12),
    axis.text.x = element_text(angle = 45, hjust = 1)
  )

# Display the overall plot
print(p_overall)

# Save the overall plot
ggsave(file.path("output/figures", "superintendent_turnover_overall.png"), 
       plot = p_overall, width = 12, height = 8, dpi = 300, bg = "white")


summary(as.factor(chars_2018$agency_type))

# turnover - Rachel White appendix table replication 
################################################################################

# Filter for years 2020-2022 and reshape the data
table_data <- turnover_by_state_year %>%
  filter(year %in% c(2020, 2021, 2022)) %>%
  select(state, year, turnover_rate) %>%
  tidyr::pivot_wider(names_from = year, values_from = turnover_rate, names_prefix = "turnover_")

# Calculate totals by year (weighted by total_districts)
totals <- turnover_by_state_year %>%
  filter(year %in% c(2020, 2021, 2022)) %>%
  group_by(year) %>%
  summarise(
    total_turnover = sum(turnover_count, na.rm = TRUE),
    total_districts = sum(total_districts, na.rm = TRUE),
    .groups = 'drop'
  ) %>%
  mutate(weighted_turnover_rate = total_turnover / total_districts) %>%
  select(year, weighted_turnover_rate) %>%
  tidyr::pivot_wider(names_from = year, values_from = weighted_turnover_rate, names_prefix = "turnover_")

# Add total row
total_row <- data.frame(
  state = "Total",
  turnover_2020 = totals$turnover_2020,
  turnover_2021 = totals$turnover_2021,
  turnover_2022 = totals$turnover_2022
)

# Add national row (rachel white data)
national_row <- data.frame(
  state = "National",
  turnover_2020 = 0.142,
  turnover_2021 = 0.169,
  turnover_2022 = 0.171
)

# Combine data with total and national rows
final_table <- rbind(table_data, total_row, national_row)

# Capitalize state abbreviations (assuming they are 2-letter abbreviations)
final_table$state <- ifelse(
  nchar(final_table$state) == 2 & final_table$state %in% c("Total", "National") == FALSE,
  toupper(final_table$state),
  final_table$state
)

# Generate LaTeX table with economics journal styling
latex_table <- paste0(
  "\\centering\n",
  "\\begin{tabular}{lccc}\n",
  "\\toprule\n",
  "State & 2020 (\\%) & 2021 (\\%) & 2022 (\\%) \\\\\n",
  "\\midrule\n"
)

# Add data rows
for(i in 1:nrow(final_table)) {
  # Add midrule before Total row for separation
  if(final_table$state[i] == "Total") {
    latex_table <- paste0(latex_table, "\\midrule\n")
  }
  
  # Format numbers without percentage signs (since they're in headers now)
  latex_table <- paste0(
    latex_table,
    final_table$state[i], " & ",
    sprintf("%.1f", final_table$turnover_2020[i] * 100), " & ",
    sprintf("%.1f", final_table$turnover_2021[i] * 100), " & ",
    sprintf("%.1f", final_table$turnover_2022[i] * 100), " \\\\\n"
  )
}

# Close table
latex_table <- paste0(
  latex_table,
  "\\bottomrule\n",
  "\\end{tabular}\n",
  "\\label{tab:turnover_rates}\n"
)

# Print the LaTeX table
cat(latex_table)

# Optional: Save to file
writeLines(latex_table, "output/figures/white_turnover_table.tex")


