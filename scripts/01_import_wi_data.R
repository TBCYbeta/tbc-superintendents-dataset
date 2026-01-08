# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Wisconsin data directory
wi_dir_path <- here("data", "raw", "wi")

files <- list.files(wi_dir_path, pattern = "*.xlsx|*csv")
all_wi_stf <- data.frame()
for(f in files){
  print(f)
  ext <- str_sub(f,nchar(f)-3,999)
  if(ext=="xlsx"){
    df <- read_xlsx(file.path(wi_dir_path, f))
    df <- df %>% select(first_raw = `First Name`, last_raw = `Last Name`, district_n = `Hire Agncy Cd`, 
                        position_code = `Position Cd`, salary = `Tot Salary`, deg_desc = `High Degree`, 
                        gender = Gndr, ethnicity = RaceEthn)
    df$district_n <- as.numeric(df$district_n)
    df$super <- ifelse(df$position_code=="05",1,0)
    df$teacher <- ifelse(df$position_code=="53",1,0)
  } else{
    df <- read_delim(file.path(wi_dir_path,f), delim = ",", skip = 1)
    df <- df %>% select(first_raw = `First Name`, last_raw = `Last Name`, district = `Hire Agency`,
                        position_raw = `Assignment Position`, salary = `Total Salary`, deg_desc = `Contract High Degree`, 
                        gender = Gender, ethnicity = RaceEthnicity)
    df$super <- ifelse(df$position_raw=="05 - District Administrator",1,0)
    df$teacher <- ifelse(df$position_raw=="53 - Teacher",1,0)
    df$district_n <- str_sub(df$district, 1, str_locate(df$district, " - ")[,1]-1) %>% as.numeric()
  }
  
  df <- df %>% mutate_all(as.character) %>% distinct()
  df$year <- str_sub(f,1,4) %>% as.numeric()
  df$file <- f
  all_wi_stf <- bind_rows(all_wi_stf, df)
  
}

all_wi_stf$district_n <- parse_number(all_wi_stf$district_n)

all_wi_supers <- all_wi_stf %>% filter(super==1)

#In cases with >1 superintendent per district per year, take the observation with the highest salary
all_wi_supers <- all_wi_supers %>% 
  mutate(salary = parse_number(salary)) %>% 
  group_by(year, district_n) %>% 
  mutate(rank_sal = rank(-salary)) %>% 
  filter(rank_sal == 1) %>% 
  select(-rank_sal)

# Map district IDs to LEAIDs
# Initialize an empty data frame
wi_distids <- data.frame()
years <- 2008:2024

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Wisconsin") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = as.character(leaid), 
           state_leaid = parse_number(str_remove_all(str_remove_all(state_leaid, "WI-"),"-")))
  
  wi_distids <- bind_rows(wi_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

all_wi_supers_lea <- inner_join(all_wi_supers, wi_distids, by = c("district_n" = "state_leaid", "year"))

# Inspect unmatched
unmatched <- anti_join(all_wi_supers, wi_distids, by = c("district_n" = "state_leaid", "year"))

all_wi_supers_lea$name_raw <- paste0(all_wi_supers_lea$first_raw, " ", all_wi_supers_lea$last_raw)
all_wi_supers_lea$name_clean <- str_to_title(clean_names(all_wi_supers_lea$name_raw))
all_wi_supers_lea$state <- "WI"

all_wi_supers_lea <- all_wi_supers_lea %>% distinct(leaid, year, name_clean, .keep_all = TRUE)
all_wi_supers_lea <- all_wi_supers_lea %>% arrange(leaid, year)
all_wi_supers_lea$id = paste0("wi", str_pad(1:nrow(all_wi_supers_lea), width = 5, side = "left", pad = "0"))

all_wi_supers_lea <- all_wi_supers_lea %>% rename(charter = agency_charter_indicator)
all_wi_supers_lea$nces_lea_name <- str_to_title(all_wi_supers_lea$nces_lea_name)

#Create table with names, district IDs, and years
all_supers <- all_wi_supers_lea %>% ungroup() %>% select(id, state, leaid, leaid_name = nces_lea_name, name_raw, name_clean, year, salary, charter)

write.csv(all_supers, "allsuperswi.csv")

summary(as.factor(all_supers$year))
summary(as.factor(unmatched$year))

# drop missing 
all_supers <- all_supers %>% filter(!is.na(name_clean)) %>%
  filter(name_clean!="")

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_wi.Rda"))

# data checks
data_checks(all_supers)
