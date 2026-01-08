# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Oregon data directory
or_dir_path <- here("data", "raw", "or")

or_raw <- data.frame()
for(y in c(2012:2018, 2020:2023)){
  print(y)
  if (y<2021){
    df <- read_delim(file = file.path(or_dir_path, paste0("RCmediaDistrictsAggregate",y,".csv")), 
                     delim = ",")
  }
  else {
    df <- read_delim(file = file.path(or_dir_path, paste0("AAGmediaDistrictsAggregate",y,".csv")), 
                     delim = ",")
  }
  
  
  df <- df %>% select(`District ID`, `District Name`, Superintendent)
  df$year <- y
  or_raw <- bind_rows(or_raw, df)

}

colnames(or_raw) <- c("dist_id","dist_name","administrator","year")

# Map district IDs to LEAIDs
# Initialize an empty data frame
or_distids <- data.frame()
years <- c(2012:2018, 2020:2023)

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Oregon") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = parse_number(leaid))
  
  or_distids <- bind_rows(or_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

or_distids$state_leaid_clean <- 
  as.numeric(str_remove_all(str_remove_all(or_distids$state_leaid, "OR-"),"-"))

or_clean <- inner_join(or_raw, or_distids, by = c("dist_id" = "state_leaid_clean", "year"))

# Inspect unmatched
unmatched <- anti_join(or_raw, or_distids, by = c("dist_id" = "state_leaid_clean", "year"))

or_clean$name_raw <- or_clean$administrator
or_clean$name_clean <- clean_names(or_clean$name_raw)

or_clean$state <- "OR"
or_clean <- or_clean %>% distinct(leaid, year, name_clean, .keep_all = TRUE)
or_clean <- or_clean %>% arrange(leaid, year)
or_clean$id <- paste0("or",str_pad(1:nrow(or_clean), width = 5, side = "left", pad = "0"))
or_clean <- or_clean %>% rename(charter = agency_charter_indicator)

#Create table with names, district IDs, and years
all_supers <- or_clean %>% select(id, state, leaid, leaid_name = dist_name, name_raw, name_clean, year, leaid, charter)

summary(as.factor(all_supers$year))

# drop missing 
all_supers <- all_supers %>% filter(!is.na(name_clean))

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_or.Rda"))

# data checks
data_checks(all_supers)