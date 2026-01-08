# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Define Illinois data directory
il_dir_path <- here("data", "raw", "il")

# Define function to clean column names
clean_cols <- function(df){
  # Get the varnames
  var_names <- colnames(df)
  
  # Clean the varnames
  for (i in 1:length(var_names)){
    var_names[i] <- str_replace_all(tolower(var_names[i]), "\\.", "_")
    var_names[i] <- str_replace_all(var_names[i], "[\r\n]" , "")
    var_names[i] <- str_replace_all(tolower(var_names[i]), " ", "_")
  }
  
  # Replace the names with the clean names
  colnames(df) <- var_names
  
  return(df)
}

# Import Illinois raw data
files <- list.files(il_dir_path, pattern = "\\.xls$", full.names = TRUE)

all_dirs <- data.frame()
for(f in files){
  print(f)
  df <- try(read_xls(f, sheet = "Public"))
  if (inherits(df, "try-error")){
    df <- try(read_xls(f, sheet = "Public Dist & Sch"))
    if (inherits(df, "try-error")){
      df <- read_xls(f, sheet = "1 Public Dist & Sch")
    }
  }
  
  df <- clean_cols(df)
  
  df$file <- f
  
  # Standardize a few variables I want
  cols <- colnames(df)
  if("cat" %in% cols){
    df$category <- df$cat
  }
  
  if("facility_name" %in% cols){
    df$facilityname <- df$facility_name
  }
  
  reg_cols <- c("region-2_county-3_district-4","region-2county-3district-4","region2county3district4")
  for(r in reg_cols){
    if(r %in% cols){
      df$state_id <- df[[r]]
    }
  }
  
  all_dirs <- bind_rows(all_dirs, df)
  df <- NULL
}

# Subset to just district (not school) entries
all_dirs_dist <- all_dirs %>% filter(parse_number(category)==2) %>% 
  select(administrator, nces_id, state_id, file, facilityname)
all_dirs_dist$state_id <- parse_number(all_dirs_dist$state_id)
table(all_dirs_dist$file)

# Add years
all_dirs_dist$year <- parse_number(str_sub(basename(all_dirs_dist$file), 1, 4))
all_dirs_dist$year <- ifelse(is.na(all_dirs_dist$year), 
                             parse_number(str_sub(all_dirs_dist$file, nchar(all_dirs_dist$file)-5, nchar(all_dirs_dist$file)-4)) + 1999, 
                             all_dirs_dist$year)
all_dirs_dist$year <- as.numeric(all_dirs_dist$year)
table(all_dirs_dist$year, useNA = "always")

# For years 2012 to 2020, IL directories report NCES IDs
table(is.na(all_dirs_dist$nces_id), all_dirs_dist$year, useNA = "always")

# Map district IDs to LEAIDs for 2003 to 2011
# Initialize an empty data frame
il_distids <- data.frame()
years_leaids <- 2002:2011

# Loop through years to load and process data
for(y in years_leaids){
  print(y)
  
  # Load Rda file
  load(file.path(dist_chars_path, paste0("chars_", y, ".Rda")))
  df <- get(paste0("chars_", y))
  
  # Process the data
  temp <- df %>% 
    filter(fips == "Illinois") %>% 
    select(year, leaid, state_leaid, nces_lea_name = lea_name, agency_charter_indicator, enrollment) %>% 
    mutate(leaid = parse_number(leaid))
  
  il_distids <- bind_rows(il_distids, temp)
  
  # Remove the loaded object
  rm(list = paste0("chars_", y))
}

# Create new state_id variable that drops "IL-" from the front of state_leaid and drops the last part of the string after the final "-"
il_distids <- il_distids %>%
  mutate(state_id = sub("^IL-", "", state_leaid),        # Remove "IL-" from the start
         state_id = sub("-[^-]+$", "", state_id),         # Remove the last part after the final "-"
         state_id = gsub("-", "", state_id),              # Remove all "-" characters
         state_id = sub("[a-zA-Z]$", "", state_id))       # Remove trailing letter (if any)

il_distids$state_id <- as.numeric(il_distids$state_id)

# Some state id values have >1 leaid associated with them (e.g. 10011720)
# Take the dist_id with the highest enrollment
# First confirm that the largest district is always substantially larger than the next largest
enr_check <- il_distids %>% group_by(year, state_id) %>% 
  filter(enrollment > 0) %>% 
  mutate(rank_enr = rank(-enrollment, ties.method = "first")) %>% 
  pivot_wider(id_cols = c(year, state_id), 
              values_from = enrollment, 
              names_from = rank_enr, 
              names_prefix = "enr") %>% 
  filter(is.na(enr2)==0)
quantile(enr_check$enr1/enr_check$enr2, seq(0,1,0.01), na.rm = T)

il_distids <- il_distids %>% group_by(year, state_id) %>% 
  filter(enrollment > 0) %>% 
  mutate(rank_enr = rank(-enrollment, ties.method = "first")) %>% 
  filter(rank_enr==1) %>% 
  select(year, leaid, state_id, nces_lea_name, agency_charter_indicator)

all_dirs_dist_02_11 <- all_dirs_dist %>% filter(year %in% 2002:2011) %>% 
  select(-nces_id) %>% 
  inner_join(., il_distids, by = c("state_id", "year"))

# Check that state_id and year are unique
check_n <- all_dirs_dist_02_11 %>% group_by(state_id, year) %>% summarize(n = n())
table(check_n$n)

# Inspect unmatched 
unmatched <- all_dirs_dist %>% filter(year %in% 2002:2011) %>% 
  select(-nces_id) %>% 
  anti_join(., il_distids, by = c("state_id", "year"))
table(unmatched$year)

all_dirs_dist_12_20 <- all_dirs_dist %>% filter(year %in% 2012:2023) %>% 
  mutate(leaid = as.numeric(nces_id)) %>% 
  filter(is.na(leaid)==0)

all_dirs_leas <- bind_rows(all_dirs_dist_02_11, all_dirs_dist_12_20)
all_dirs_leas$name_raw <- all_dirs_leas$administrator
all_dirs_leas$name_clean <- clean_names(all_dirs_leas$name_raw)
all_dirs_leas$state <- "IL"
all_dirs_leas <- all_dirs_leas %>% distinct(leaid, year, name_clean, agency_charter_indicator, .keep_all = TRUE)
all_dirs_leas <- all_dirs_leas %>% arrange(leaid, year)
all_dirs_leas$id <- paste0("il",str_pad(1:nrow(all_dirs_leas), width = 5, side = "left", pad = "0"))
all_dirs_leas <- all_dirs_leas %>% rename(charter = agency_charter_indicator)

# Create table with names, district IDs, and years
all_supers <- all_dirs_leas %>% select(id, state, leaid, leaid_name = nces_lea_name, name_raw, name_clean, year, leaid, charter)
all_supers$leaid_name <- str_to_title(all_supers$leaid_name)

# Save the processed data
save(all_supers, file = file.path(clean_path, "all_supers_il.Rda"))

# data checks
data_checks(all_supers)


