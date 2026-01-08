# Close all connections and clear environment
closeAllConnections()
rm(list = ls())

source(here::here("scripts/00_setup.R"))

# Updated States
  states <- c("ar", "ca", "ct", "fl", "ga", "ia", "il", "in", "ks", "mi",
              "mo", "nc", "ne", "nj", "ny", "oh", "ok", "or", "pa", "tn", 
              "tx", "va", "wi")
  
# Run all import scripts
#for (state in states) {
#  script_path <- file.path("scripts", paste0("01_import_", state, "_data.R"))
#  if (file.exists(script_path)) {
#    message("Running: ", script_path)
#    env <- new.env()
#   # Quietly run the script in an isolated environment
#   sys.source(script_path, envir = env)
#  } else {
#    warning("Script not found: ", script_path)
#  }
#}

# Load processed .Rda files and bind
supers_list <- list()

for (state in states) {
  rda_path <- file.path("data", "processed", paste0("all_supers_", state, ".Rda"))
  if (file.exists(rda_path)) {
    message("Loading: ", rda_path)
    load(rda_path)
    supers_list[[state]] <- get("all_supers")
  } else {
    warning("Processed file not found: ", rda_path)
  }
}


# Convert all leaid columns to character before binding
supers_list <- map(supers_list, ~ .x %>% mutate(leaid = as.character(leaid)))
all_supers <- bind_rows(supers_list, .id = "state")


summary(as.factor(all_supers$year))
summary(as.factor(all_supers$state))
summary(is.na(all_supers$salary))


# clean names and combine different names of same superintendents
all_supers$name_clean <- gsub("\\biii\\b", "", all_supers$name_clean, ignore.case = TRUE)
all_supers$name_clean <- trimws(all_supers$name_clean)
tmp <- all_supers %>%
  mutate(
    nm   = str_squish(str_to_lower(name_clean)),
    last = str_squish(str_to_lower(word(nm, -1)))
  )

canon <- tmp %>%
  group_by(leaid, last) %>%
  arrange(desc(year), desc(nchar(nm))) %>%
  summarize(canon_name = first(nm[!is.na(nm)]), .groups = "drop")

all_supers <- all_supers %>%
  mutate(
    nm   = str_squish(str_to_lower(name_clean)),
    last = str_squish(str_to_lower(word(nm, -1)))
  ) %>%
  left_join(canon, by = c("leaid","last")) %>%
  mutate(
    name_clean = str_squish(if_else(!is.na(canon_name), canon_name, nm))
  ) %>%
  select(-nm, -last, -canon_name)


# unique superintendent ID
all_supers <- all_supers %>%
  group_by(state, name_clean) %>%
  mutate(super_id = paste0(first(state), "_", str_pad(cur_group_id(), width = 5, side = "left", pad = "0"))) %>%
  ungroup()

all_supers %>%
  summarise(unique_super_ids = n_distinct(super_id))

# padding 0s in LEAIDs
all_supers <- all_supers %>%
  mutate(leaid = ifelse(nchar(leaid) == 6, paste0("0", leaid), leaid))
all_supers <- all_supers %>% distinct(leaid, year, name_clean, .keep_all = TRUE)


# fill in missing charter where needed
library(zoo)
all_supers <- all_supers %>%
  group_by(leaid) %>%
  arrange(year, .by_group = TRUE) %>%
  mutate(
    charter_prev = na.locf(charter, na.rm = FALSE),
    year_prev    = na.locf(ifelse(!is.na(charter), year, NA_integer_), na.rm = FALSE),
    charter_next = na.locf(charter, fromLast = TRUE, na.rm = FALSE),
    year_next    = na.locf(ifelse(!is.na(charter), year, NA_integer_), fromLast = TRUE, na.rm = FALSE),
    charter = if_else(
      is.na(charter),
      case_when(
        is.na(charter_prev) & is.na(charter_next) ~ NA_character_,
        is.na(charter_prev)                       ~ charter_next,
        is.na(charter_next)                       ~ charter_prev,
        abs(year - year_prev) <  abs(year - year_next) ~ charter_prev,
        abs(year - year_prev) >  abs(year - year_next) ~ charter_next,
        TRUE ~ charter_next  # equal distance -> choose most recent (higher year)
      ),
      charter
    )
  ) %>%
  select(-charter_prev, -year_prev, -charter_next, -year_next) %>%
  ungroup()

# fix stray observation 
all_supers$leaid[all_supers$name_clean == "theresa perry"] <- 3700000
all_supers <- all_supers[order(all_supers$super_id), ]

# Save combined data
save(all_supers, file = file.path("data", "processed", "combined_superintendents.Rda"))
write.csv(all_supers, file = file.path("data", "processed", "combined_superintendents.csv"), row.names = FALSE)

