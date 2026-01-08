# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

library(pdftools)
library(dplyr)
library(stringr)

source(here::here("scripts/00_setup.R"))

# Define kansas data directory
ks_dir_path <- here("data", "raw", "ks")

years <- c(2009:2018, 2021:2024)

ks_combined <- data.frame()
for(y in years){
  df <- read_xlsx(file.path(ks_dir_path, "KS_Superintendents.xlsx"), sheet = as.character(y))
  df$USD <- as.numeric(df$USD)
  df$year <- y
  ks_combined <- bind_rows(ks_combined, df)
}


# Map district IDs to LEAIDs
# Initialize an empty data frame
ks_distids <- data.frame()

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Kansas") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = as.character(leaid))
  
  ks_distids <- bind_rows(ks_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

# Clean state_ids
ks_distids$state_id <- str_remove_all(ks_distids$state_leaid, "KS-")

# Restrict to "D" districts
ks_distids <- ks_distids %>% filter(str_sub(state_id,1,1)=="D")

# Convert to numeric
ks_distids$state_id <- as.numeric(str_sub(ks_distids$state_id, 2, 999))

ks_combined_lea <- inner_join(ks_combined, ks_distids, by = c("year","USD"="state_id"))

# Check unmatched
unmatched <- anti_join(ks_combined, ks_distids, by = c("year","USD"="state_id"))

table(unmatched$year)

ks_combined_lea$state <- "KS"
ks_combined_lea <- ks_combined_lea %>% distinct(leaid, year, NAME, .keep_all = TRUE)
ks_combined_lea <- ks_combined_lea %>% arrange(leaid, year)
ks_combined_lea$id <- paste0("ks", str_pad(1:nrow(ks_combined_lea), width = 5, side = "left", pad = "0"))
ks_combined_lea$name_raw <- ks_combined_lea$NAME
ks_combined_lea$name_clean <- clean_names(ks_combined_lea$name_raw)
ks_combined_lea <- ks_combined_lea %>% rename(charter = agency_charter_indicator)


# Create table with names, district IDs, and years
all_supers <- ks_combined_lea %>% filter(is.na(leaid)==0) %>% 
  select(id, state, leaid, leaid_name = nces_lea_name, name_raw, name_clean, year, leaid, charter) %>% ungroup()
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)

summary(as.factor(all_supers$year))

# drop NA rows 
all_supers <- all_supers %>% filter(!is.na(name_raw))

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_ks.Rda"))

# data checks
data_checks(all_supers)