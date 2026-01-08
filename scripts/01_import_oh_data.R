# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Ohio data directory
oh_dir_path <- here("data", "raw", "oh")

files <- c("OH 2005-06.xlsx", "OH 2006-07.XLS", "OH 2007-08.XLS",  #2005-2007 are new from John Singleton
           "0809_LRC_DISTRICT.XLS", "0910_LRC_DISTRICT.XLS", 
           "1011_LRC_DISTRICT.xls", "1112_LRC_DISTRICT.xls", 
           "1213_LRC_DISTRICT.xls", "1314_LRC_DISTRICT.xls", 
           "1415_LRC_DISTRICT.xls", "DISTRICT_HIGH_LEVEL_1516.xls",
           "1617_DISTRICT_HIGH_LEVEL_FINAL_W_ENRL.xls", "DISTRICT_HIGH_LEVEL_1718.xlsx",
           "CONTACT_INFORMATION_1819.xlsx", "CONTACT_INFORMATION_1920.xlsx", "CONTACT_INFORMATION_2021.xlsx",
           "Contact_Information_2122.xlsx", "Contact_Information_2023.xlsx", "Contact_Information_2024.xlsx")
files_df <- data.frame(file = files, 
                       year = 2005:2023)

oh_raw <- data.frame()

for(f in 1:nrow(files_df)){
  if(files_df$year[f] >= 2018) {
    df <- read_excel(path = file.path(oh_dir_path, files_df$file[f]), 
                     sheet = 2) %>% 
      select(`District IRN`, Superintendent)
  } 
  else {
    df <- read_excel(path = file.path(oh_dir_path, files_df$file[f])) %>% 
      select(`District IRN`, Superintendent)
  }
  
  colnames(df) <- c("dist_raw","superintendent")
  df$year <- files_df$year[f]
  
  oh_raw <- bind_rows(df, oh_raw)
}

oh_raw$dist_raw <- as.numeric(oh_raw$dist_raw)
oh_raw <- oh_raw %>% filter(is.na(superintendent)==0)

summary(as.factor(oh_raw$year))
# Map district IDs to LEAIDs
# Initialize an empty data frame
oh_distids <- data.frame()
years <- 2005:2023

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Ohio") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = parse_number(leaid))
  
  oh_distids <- bind_rows(oh_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

oh_distids$state_leaid_clean <- 
  str_remove_all(str_remove_all(tolower(oh_distids$state_leaid), "oh"),"-")
oh_distids$state_leaid_clean <- as.numeric(oh_distids$state_leaid_clean)

all_oh_lea <- left_join(oh_raw, oh_distids, by = c("dist_raw" = "state_leaid_clean", "year"))

# Inspect unmatched
unmatched <- anti_join(oh_raw, oh_distids, by = c("dist_raw" = "state_leaid_clean", "year"))

all_oh_lea <- all_oh_lea %>% arrange(year)
all_oh_lea$state <- "oh"
all_oh_lea <- all_oh_lea %>% distinct(leaid, year, superintendent, .keep_all = TRUE)
all_oh_lea <- all_oh_lea %>% arrange(leaid, year)
all_oh_lea$id <- paste0("oh",str_pad(1:nrow(all_oh_lea), width = 5, side = "left", pad = "0"))

all_oh_lea$name_raw <- all_oh_lea$superintendent
all_oh_lea$name_clean <- clean_names(all_oh_lea$name_raw)
all_oh_lea <- all_oh_lea %>% rename(charter = agency_charter_indicator)

#Create table with names, district IDs, and years
all_supers <- all_oh_lea %>% select(id, state, leaid, leaid_name = nces_lea_name, name_raw, name_clean, year, leaid, charter)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)
all_supers$leaid_name <- gsub("School District|Schools District", "", all_supers$leaid_name)
all_supers$leaid_name <- trimws(all_supers$leaid_name)

# drop vacant names 
all_supers <- all_supers %>%
  filter(name_clean!="vacant position") 

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_oh.Rda"))

#write.csv(all_supers, "all_supers_oh.csv")

# data checks
data_checks(all_supers)

write.csv(all_supers, "all_supers_oh.csv")
