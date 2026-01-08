# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Arkansas data directory
ar_dir_path <- here("data", "raw", "ar")

# Import AR raw data
files <- list.files(ar_dir_path, pattern = "*.xls", full.names = TRUE)


ar_raw <- data.frame()
for(f in files){
  print(f)
  df <- read_excel(f, skip = 1)
  df <- df %>% select(dist_raw = `District LEA`, 
                      dist_name_raw = `District Description`, 
                      administrator = `Full Name`) %>% 
    mutate(year = as.numeric(str_extract(f, "\\d{4}"))) %>% 
    filter(is.na(dist_name_raw)==0)
  ar_raw <- bind_rows(ar_raw, df)
}
ar_raw$dist_raw <- as.numeric(ar_raw$dist_raw)

# Two district are reported twice
# Remove one manually that appears to be erroneous
ar_raw$drop <- 0
ar_raw$drop <- ifelse(ar_raw$dist_raw==6103000 & 
                        ar_raw$dist_name_raw=="POCAHONTAS SCHOOL DISTRICT" &
                        ar_raw$administrator=="BUSBY, BYRON B." & 
                        ar_raw$year==2008, 1, ar_raw$drop)
ar_raw <- ar_raw %>% filter(drop==0) %>% select(-drop)

# The other is just a repeated row
ar_raw <- ar_raw %>% ungroup() %>% distinct()

# Map district IDs to LEAIDs
# Initialize an empty data frame
ar_distids <- data.frame()
years <- 2007:2024

# Loop through years to load and process data
for(y in years){
  print(y)

  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Arkansas") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = if(is.character(leaid)) {
             parse_number(leaid)
           } else {
             as.numeric(leaid)  # If already numeric, just ensure it's numeric
           }, 
           state_leaid_n = as.numeric(str_remove_all(state_leaid, "AR-")))
  
  ar_distids <- bind_rows(ar_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

# Merge with `ar_raw`
all_ar_lea <- inner_join(ar_raw, ar_distids, by = c("dist_raw" = "state_leaid_n", "year"))

# Check the districts that don't merge
non_merged <- anti_join(ar_raw, ar_distids, by = c("dist_raw" = "state_leaid_n", "year"))

# FRIENDSHIP ASPIRE ACADEMY LITTLE ROCK is missing in 2018
# This district shows up in CCD/Urban Inst. data starting in 2019+

# Add state and ID fields
all_ar_lea <- all_ar_lea %>% distinct(leaid, year, administrator, .keep_all = TRUE)
all_ar_lea <- all_ar_lea %>% arrange(leaid, year)
all_ar_lea <- all_ar_lea %>%
  mutate(state = "AR",
         id = paste0("ar", str_pad(1:nrow(all_ar_lea), width = 5, side = "left", pad = "0")),
         name_raw = administrator,
         name_clean = clean_names(name_raw))
all_ar_lea <- all_ar_lea %>% rename(charter = agency_charter_indicator)

# Create table with relevant columns
all_supers <- all_ar_lea %>% select(id, state, leaid, leaid_name = nces_lea_name, name_raw, name_clean, year, charter)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_ar.Rda"))

# data checks 
data_checks(all_supers)
