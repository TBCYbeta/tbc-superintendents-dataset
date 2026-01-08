# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Nebraska data directory
ne_dir_path <- here("data", "raw", "ne")
ne_raw <- data.frame()

# Loop through years from 2001 to 2024
for(y in 2001:2024){
  # Create the filename based on the year (e.g., 02_03.txt for 2002)
  y_short <- substr(as.character(y), 3, 4)
  next_y_short <- substr(as.character(y + 1), 3, 4)
  filename <- paste0(y_short, "_", next_y_short, ".txt")
  
  # Full file path
  file_path <- file.path(ne_dir_path, filename)
  
  # Check if file exists before trying to read it
  if(file.exists(file_path)) {
    print(paste("Reading file for year:", y, "-", filename))
    
    # Read the comma-separated txt file
    df <- read.csv(file_path, header = TRUE, stringsAsFactors = FALSE)
    
    # Check if the file has the columns we need
    required_cols <- c("LastName", "FirstName", "Name", "FTE", "AgencyID", "StaffID")
    if(all(required_cols %in% colnames(df))) {
      # All required columns exist, proceed with processing
      print("All required columns found")
      
      df <- df[, required_cols]
      df$StaffID <- as.character(df$StaffID)
      
      # Filter and select relevant data
      df <- df %>% 
        mutate(year = y) 
      
      print(paste("Number of rows:", nrow(df)))
      
      # Append to the main dataframe
      ne_raw <- bind_rows(ne_raw, df)
    } 
  else {
      warning(paste("File", filename, "does not have the expected number of columns."))
    }
  } else {
    warning(paste("File", filename, "does not exist. Skipping year", y))
  }
}

summary(as.factor(ne_raw$year))

# Map district IDs to LEAIDs
# Initialize an empty data frame
ne_distids <- data.frame()
years <- 2001:2024

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Nebraska") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = if(is.character(leaid)) parse_number(leaid) else as.numeric(leaid))
  
  
  ne_distids <- bind_rows(ne_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

ne_distids$state_leaid_clean <- str_remove_all(str_remove_all(ne_distids$state_leaid, "NE"),"-")
ne_distids$state_leaid_clean <- as.numeric(ne_distids$state_leaid_clean)

# clean up ne_raw before merge 
ne_raw$dist_no_num <- str_remove_all(ne_raw$AgencyID, "-")
ne_raw$dist_no_num <- as.numeric(ne_raw$dist_no_num)

ne_raw = ne_raw %>%
            mutate(administrator = paste(FirstName, LastName))

#In cases with >1 superintendent per district per year, take the observation with the highest salary
ne_raw <- ne_raw %>% group_by(year, AgencyID) %>%
  mutate(rank_fte = rank(-FTE)) %>%
  filter(rank_fte == 1) %>%
  select(-rank_fte)

# merge
ne_lea <- left_join(ne_raw, ne_distids, by = c("dist_no_num"="state_leaid_clean", "year"))

summary(as.factor(ne_raw$year))
summary(as.factor(ne_distids$year))
summary(as.factor(ne_lea$year[!is.na(ne_lea$leaid)]))
summary(as.factor(ne_lea$year))


ne_lea$name_raw <- ne_lea$administrator
ne_lea$name_clean <- clean_names(ne_lea$name_raw)

ne_lea$state <- "NE"
ne_lea <- ne_lea %>% distinct(leaid, year, name_clean, .keep_all = TRUE)
ne_lea <- ne_lea %>% arrange(leaid, year)
ne_lea$id <- paste0("ne",str_pad(1:nrow(ne_lea), width = 5, side = "left", pad = "0"))
ne_lea <- ne_lea %>% rename(charter = agency_charter_indicator)

# drop if LEAID missing (usually non-public school) or name missing 
ne_lea <- ne_lea %>%
  filter(!is.na(leaid), !is.na(administrator))

#Create table with names, district IDs, and years
all_supers <- ne_lea %>% 
              ungroup() %>%
              select(id, state, leaid, leaid_name = nces_lea_name, name_raw, name_clean, year, leaid, charter)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_ne.Rda"))

# data checks
data_checks(all_supers)