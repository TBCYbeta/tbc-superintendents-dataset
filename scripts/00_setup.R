# setup.R - Load libraries and define paths

# Load required packages
library(here)
library(readxl)
library(writexl)
library(tidyverse)
library(pdftools)
library(knitr)
library(kableExtra)
library(gender)
library(wru)
library(educationdata)
library(stargazer)


# Define paths relative to project root
dist_chars_path <- here("data", "raw", "urban_inst")
clean_path <- here("data", "processed")

# Print message to confirm setup
message("Setup complete: Libraries loaded and paths set.")

clean_names <- function(string){
  newstring <- str_replace_all(string, "//?","N")
  newstring <- str_trim(tolower(newstring))
  
  #For strings with commas (last, first) flip the order (first last)
  print("flipping last, first to first last")
  has_comma <- (1:length(newstring))[which(str_detect(newstring, ","))]
  j <- 1
  for(i in has_comma){
    if(j %% 100000==0){
      print(paste(j, "of", length(has_comma)))
    }
    s <- newstring[i]
    loc <- str_locate(s, ",")[1,1]
    t <- paste0(str_sub(s, loc + 1, nchar(s)), " ", str_sub(s, 1, loc-1)) %>% 
      str_trim(.)
    newstring[i] <- t
    j <- j + 1
  }
  
  #Remove Mrs. Ms. Dr. Mr.
  print("removing mr. ms. etc.")
  prefixes_to_remove <- c("mrs","ms","dr","mr","miss")
  prefixes_to_remove <- c(prefixes_to_remove, paste0(prefixes_to_remove, "."))
  remove_first_word <- (word(newstring, 1) %in% prefixes_to_remove)
  remove_first_word <- (1:length(newstring))[remove_first_word]
  j <- 1
  for(i in remove_first_word){
    if(j %% 100000==0){
      print(paste(j, "of", length(remove_first_word)))
    }
    s <- newstring[i]
    len_word1 <- nchar(word(s, 1))
    t <- str_sub(s, len_word1 + 1, 9999) %>% str_trim()
    newstring[i] <- t
    j <- j + 1
  }
  
  #Remove middle initials from names
  remove_mi <- ifelse(nchar(word(newstring, 2))==1 |
                        nchar(word(newstring, 2))==2 & str_sub(word(newstring, 2),2,2)==".",
                      T, F)
  remove_mi <- ifelse(is.na(remove_mi)==1,F,remove_mi)
  remove_mi <- (1:length(newstring))[remove_mi]
  print("removing middle initials")
  j <- 1
  for(i in remove_mi){
    if(j %% 100000==0){
      print(paste(j, "of", length(remove_mi)))
    }
    s <- newstring[i]
    # nwords <- str_count(s, '\\w+')
    nwords <- nrow(str_locate_all(s, " ")[[1]]) + 1
    t <- paste0(word(s, 1, 1)," ",word(s, 3, nwords))
    newstring[i] <- t
    j <- j + 1
  }
  
  newstring <- gsub('[[:punct:] ]+',' ',newstring)
  
  return(newstring)
  
}


# quick check for all_supers datasets
data_checks <- function(df){
  
  # Check for missing, vacant, or NA superintendent names
  missing_count <- sum(is.na(df$name_clean) | 
                         df$name_clean == "" | 
                         tolower(df$name_clean) == "vacant" |
                         tolower(df$name_clean) == "na")
  print(paste("Number of missing/vacant/NA superintendent names:", missing_count))
  
  if(missing_count > 0) {
    print("Rows with missing/vacant/NA superintendent names:")
    missing_rows <- which(is.na(df$name_clean) | 
                            df$name_clean == "" | 
                            tolower(df$name_clean) == "vacant" |
                            tolower(df$name_clean) == "na")
    print(head(missing_rows, 10))  # Show first 10 row numbers
  }
  
  # Check for complete duplicate rows
  duplicate_rows <- sum(duplicated(df))
  print(paste("Number of duplicate rows:", duplicate_rows))
  
  if(duplicate_rows > 0) {
    print("First few duplicate rows:")
    print(head(df[duplicated(df), ], 5))
  }
  
  # Check for duplicates by year and leaid (assuming these columns exist)
  if("year" %in% colnames(df) && "leaid" %in% colnames(df)) {
    year_leaid_duplicates <- sum(duplicated(df[, c("year", "leaid")]))
    print(paste("Number of duplicate year-leaid combinations:", year_leaid_duplicates))
    
    if(year_leaid_duplicates > 0) {
      print("ALL duplicate year-leaid combinations:")
      duplicate_combinations <- df[duplicated(df[, c("year", "leaid")]) | 
                                     duplicated(df[, c("year", "leaid")], fromLast = TRUE), ]
      # Sort by year and leaid for better readability
      duplicate_combinations <- duplicate_combinations[order(duplicate_combinations$year, duplicate_combinations$leaid), ]
      print(duplicate_combinations[, c("year", "leaid", "name_clean")])
    }
  } else {
    print("Warning: 'year' or 'leaid' columns not found in dataset")
    print("Available columns:")
    print(colnames(df))
  }
  print("Summary of year variable as factor")
  if("year" %in% colnames(df)) {
    year_summary <- summary(as.factor(df$year))
    print(year_summary)
  } else {
    print("Warning: 'year' column not found in dataset")
  }
  
  print("Summary of leaid character length as factor")
  if("leaid" %in% colnames(df)) {
    leaid_nchar_summary <- summary(as.factor(nchar(df$leaid)))
    print(leaid_nchar_summary)
  } else {
    print("Warning: 'leaid' column not found in dataset")
  }
  
  
  # Summary
  print("--- Summary ---")
  print(paste("Total rows:", nrow(df)))
  print(paste("Missing/vacant superintendent names:", missing_count))
  print(paste("Complete duplicate rows:", duplicate_rows))
  if("year" %in% colnames(df) && "leaid" %in% colnames(df)) {
    print(paste("Duplicate year-leaid combinations:", year_leaid_duplicates))
  }
}