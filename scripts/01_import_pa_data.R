# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Oregon data directory
pa_dir_path <- here("data", "raw", "pa")

# Import column map
colmap <- read_delim(file.path(pa_dir_path, "PA_Column_Map.csv"), delim = ",")

files <- list.files(pa_dir_path, pattern = "*.xlsx")
all_pa_stf <- data.frame()

for(f in files){
  print(f)
  df <- read_xlsx(file.path(pa_dir_path, f))
  
  #Manually fix position code/desc issue
  if(f %in% files[1:2]){
    df$PositionDescription <- df$Position
    df$Position <- NULL
  }
  
  # Create a named vector for easy lookup
  col_mapping <- setNames(colmap$col, colmap$cols)
  
  # Rename columns that have mappings
  cols_to_rename <- intersect(names(col_mapping), colnames(df))
  for(old_col in cols_to_rename) {
    new_col <- col_mapping[old_col]
    df[[new_col]] <- df[[old_col]]
    df[[old_col]] <- NULL
  }
  
  keepcols <- intersect(c("aun", "lea_name","pub_id","first","last","assignment","assign_code","position","position_desc","sal",
                          "degree","deg_code",
                          "tot_yrs_exp","gender","tot_yrs_exp"),
                        colnames(df))
  
  df <- df %>% select(all_of(keepcols)) %>% 
    mutate_all(as.character) %>% distinct()
  df$file <- f
  all_pa_stf <- bind_rows(all_pa_stf, df)
  
}

all_pa_stf$aun <- parse_number(str_remove_all(all_pa_stf$aun,"-"))
all_pa_stf$year <- parse_number(str_sub(all_pa_stf$file,1,4))

# label superintendents with assignment code for more recent years where assign_code is missing 
all_pa_stf <- all_pa_stf %>%
  mutate(assign_code = ifelse(assignment %in% c("Superintendent", "Acting Superintendent", "District Superintendent"), 
                              "1150", 
                              assign_code))

# Restrict to superintendents
all_pa_supers <- all_pa_stf %>% filter(assign_code %in% 1150:1151)

summary(as.factor(all_pa_supers$position_desc))

#In cases with >1 superintendent per district per year, take the observation with the highest salary
all_pa_supers <- all_pa_supers %>% 
  mutate(salary = parse_number(sal)) %>% 
  group_by(year, aun) %>% 
  mutate(rank_sal = rank(-salary)) %>% 
  filter(rank_sal == 1) %>% 
  select(-rank_sal)

# Map district IDs to LEAIDs
# Initialize an empty data frame
pa_distids <- data.frame()
years <- 2008:2024

# Loop through years to load and process data
for(y in years){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Pennsylvania") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = parse_number(as.character(leaid)))
  
  pa_distids <- bind_rows(pa_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

pa_distids$state_leaid_clean <- 
  as.numeric(str_remove_all(str_remove_all(pa_distids$state_leaid, "PA-"),"-"))

all_pa_supers_lea <- inner_join(all_pa_supers, pa_distids, by = c("aun"="state_leaid_clean","year"))

# Inspect unmatched
unmatched <- anti_join(all_pa_supers, pa_distids, by = c("aun"="state_leaid_clean","year"))

all_pa_supers_lea$name_raw <- paste0(all_pa_supers_lea$first, " ", all_pa_supers_lea$last)
all_pa_supers_lea$name_clean <- clean_names(all_pa_supers_lea$name_raw)
all_pa_supers_lea$state <- "PA"
all_pa_supers_lea <- all_pa_supers_lea %>% distinct(leaid, year, name_clean, .keep_all = TRUE)
all_pa_supers_lea <- all_pa_supers_lea %>% arrange(leaid, year)
all_pa_supers_lea$id <- paste0("pa",str_pad(1:nrow(all_pa_supers_lea), width = 5, side = "left", pad = "0"))
all_pa_supers_lea <- all_pa_supers_lea %>% rename(charter = agency_charter_indicator)
all_supers <- all_pa_supers_lea %>% ungroup() %>%  select(id, state, leaid, leaid_name = lea_name, name_raw, name_clean, year, leaid, salary, charter)

summary(as.factor(all_supers$year))


# drop missing 
all_supers <- all_supers %>% filter(!is.na(name_clean))

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_pa.Rda"))

# data checks
data_checks(all_supers)
