# Close all connections and clear environment
closeAllConnections()
rm(list = ls())


# Create district files from Urban Institute for years as needed
urban_inst_path <- here("data", "raw", "urban_inst")

charter_levels <- c("All charter schools", "Some charter schools", "No charter schools", "Not applicable")

state_names <- c("Alabama"                        ,                                                               
                 "Alaska"                         ,                                                               
                 "American Samoa"                 ,                                                               
                 "Arizona"                        ,                                                               
                 "Arkansas"                       ,                                                               
                 "California"                     ,                                                               
                 "Canal Zone"                     ,                                                               
                 "Colorado"                       ,                                                               
                 "Connecticut"                    ,                                                               
                  "Delaware"                      ,                                                                
                  "District of Columbia"          ,                                                                
                  "Florida"                       ,                                                                
                  "Georgia"                       ,                                                                
                  "Guam"                          ,                                                                
                  "Hawaii"                        ,                                                                
                  "Idaho"                         ,                                                                
                  "Illinois"                      ,                                                                
                  "Indiana"                       ,                                                                
                  "Iowa"                          ,                                                                
                  "Kansas"                        ,                                                                
                  "Kentucky"                      ,                                                                
                  "Louisiana"                     ,                                                                
                  "Maine"                         ,                                                                
                  "Maryland"                      ,                                                                
                  "Massachusetts"                 ,                                                                
                  "Michigan"                      ,                                                                
                  "Minnesota"                     ,                                                                
                  "Mississippi"                   ,                                                                
                  "Missouri"                      ,                                                                
                  "Montana"                       ,                                                                
                  "Nebraska"                      ,                                                                
                  "Nevada"                        ,                                                                
                  "New Hampshire"                 ,                                                                
                  "New Jersey"                    ,                                                                
                  "New Mexico"                    ,                                                                
                  "New York"                      ,                                                                
                  "North Carolina"                ,                                                                
                  "North Dakota"                  ,                                                                
                  "Ohio"                          ,                                                                
                  "Oklahoma"                      ,                                                                
                  "Oregon"                        ,                                                                
                  "Pennsylvania"                  ,                                                                
                  "Puerto Rico"                   ,                                                                
                  "Rhode Island"                  ,                                                                
                  "South Carolina"                ,                                                                
                  "South Dakota"                  ,                                                                
                  "Tennessee"                     ,                                                                
                  "Texas"                         ,                                                                
                  "Utah"                          ,                                                                
                  "Vermont"                       ,                                                                
                  "Virginia"                      ,                                                                
                  "Virgin Islands of the US"      ,                                                                
                  "Washington"                    ,                                                                
                  "West Virginia"                 ,                                                                
                  "Wisconsin"                     ,                                                                
                  "Wyoming"                       ,                                                                
                  "Department of Defense Dependent Schools (overseas)"     ,                                      
                  "Bureau of Indian Education"                             ,                                      
                  "Department of Defense Dependent Schools (domestic)"     ,                                      
                  "Department of Defense Education Activity"               ,                                      
                  "Federated States of Micronesia"                         ,                                      
                  "Mariana Islands waters (including Guam)"                ,                                      
                  "Johnston Atoll"                                         ,                                      
                  "Marshall Islands"                                       ,                                      
                  "Northern Mariana Islands"                               ,                                      
                  "Palau"                                                  ,                                      
                  "Midway Islands"                                         ,                                      
                  "US Minor Outlying Islands"                              ,                                      
                  "Atlantic coast from North Carolina to Florida and the coasts of Puerto Rico and Virgin Islands",
                  "Navassa Island"               ,                                                                 
                  "Wake Island"                  ,                                                                 
                  "Baker Island"                 ,                                                                 
                  "Howland Island"               ,                                                                 
                  "Jarvis Island"                ,                                                                 
                  "Kingman Reef"                 ,                                                                 
                  "Palmyra Atoll"                ,                                                                 
                  "Missing/not reported"         ,                                                                 
                  "Not applicable"               ,                                                                 
                  "Suppressed data")


for(year in 1990:1998) {
  # change year range to update Urban Institute API search
  
  data <- get_education_data(level = "school-districts",
                             source = "ccd",
                             topic = "directory",
                             filters = list(year = year))
  
  # Convert agency_charter_indicator to factor with consistent levels
  data <- data %>%
    mutate(
      agency_charter_indicator = case_when(
        agency_charter_indicator == TRUE ~ "All charter schools",
        agency_charter_indicator == FALSE ~ "No charter schools",
        TRUE ~ NA_character_
      ) %>% factor(levels = charter_levels),
      fips = factor(fips, 
                          levels = 1:length(state_names),
                          labels = state_names)
    )
  
  assign(paste0("chars_", year), data)
  
  save(list = paste0("chars_", year), 
       file = file.path(urban_inst_path, paste0("chars_", year, ".Rda")))
  
}

# manually process 2024 CCD data 
file_path <- file.path(urban_inst_path, "ccd_lea_029_2324_w_1a_073124.csv")
data <- read.csv(file_path)

# modify variable names and filter 
data <- data %>%
  rename(
    leaid = LEAID,
    state_leaid = ST_LEAID,
    lea_name = LEA_NAME,
    agency_charter_indicator = CHARTER_LEA
  ) %>%
  mutate(year = 2024,
         enrollment = 0,
         # Convert to factor with consistent levels
         agency_charter_indicator = case_when(
           agency_charter_indicator == "Y" ~ "All charter schools",
           agency_charter_indicator == "N" ~ "No charter schools",
           TRUE ~ NA_character_
         ) %>% factor(levels = charter_levels),
         fips = factor(FIPST, 
                       levels = 1:length(state_names),
                       labels = state_names))

chars_2024 <- data
save(chars_2024, file = file.path(urban_inst_path, "chars_2024.Rda"))

# 
# # # # # # SCRAP 
# 
# # Define the analysis function
# check_agency_charter_indicator <- function(year) {
#   # Define path
#   dist_chars_path <- here("data", "raw", "urban_inst")
#   
#   # Load the file
#   file_path <- file.path(dist_chars_path, paste0("chars_", year, ".Rda"))
#   if (!file.exists(file_path)) {
#     return(data.frame(year = year, exists = FALSE, type = NA, values = NA))
#   }
#   
#   # Load the data
#   load(file_path)
#   df <- get(paste0("chars_", year))
#   
#   # Check if column exists
#   if (!"agency_charter_indicator" %in% names(df)) {
#     return(data.frame(year = year, exists = TRUE, type = "column missing", values = NA))
#   }
#   
#   # Get variable type
#   var_type <- class(df$agency_charter_indicator)[1]
#   
#   # Get unique values
#   unique_vals <- paste(sort(unique(df$agency_charter_indicator)), collapse = ", ")
#   
#   # Clean up
#   rm(list = paste0("chars_", year))
#   
#   # Return results
#   return(data.frame(year = year, exists = TRUE, type = var_type, values = unique_vals))
# }
# 
# # Apply to all years
# years <- 2007:2024
# results <- bind_rows(lapply(years, check_agency_charter_indicator))
# 
# # Print summary
# print(results)