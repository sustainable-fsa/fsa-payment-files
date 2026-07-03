# update.packages(repos = "https://cran.rstudio.com/",
#                 ask = FALSE)

install.packages("pak",
                 repos = "https://cran.rstudio.com/")

# installed.packages() |>
#   rownames() |>
#   pak::pkg_install(upgrade = TRUE,
#                  ask = FALSE)

pak::pak(
  c(
    "magrittr",
    "tidyverse",
    "furrr",
    "paws",
    "future.mirai"
  )
)

library(magrittr)
library(tidyverse)
library(furrr)
library(paws)
library(future.mirai)

update_payments <- TRUE

if(update_payments){
  raw_path <- "data-raw"
  
  dir.create(raw_path,
             recursive = TRUE,
             showWarnings = FALSE)
  
  raw_files <-
    xml2::read_html("https://www.fsa.usda.gov/news-room/efoia/electronic-reading-room/frequently-requested-information/payment-files-information/index") %>%
    xml2::xml_find_all(".//a") %>%
    xml2::xml_attr("href") %>%
    stringr::str_subset("xls|pmt24|pmt25") %>%
    stringr::str_remove("^\\/") %>%
    {
      tibble::tibble(
        request = file.path("https://www.fsa.usda.gov",.)
      )
    } %>%
    dplyr::rowwise() %>%
    dplyr::mutate(
      request = ifelse(stringr::str_detect(request, "xlsx"),
                       request,
                       xml2::read_html(request) %>%
                         xml2::xml_find_all(".//a") %>%
                         xml2::xml_attr("href") %>%
                         stringr::str_subset("xls")
      ),
      outfile = 
        file.path(raw_path, 
                  basename(request)) %>%
        stringr::str_replace_all("%20", " ")
    )
  
  
  plan(mirai_multisession)
  
  dl_if_missing <-
    function(x, out){
      if(file.exists(out))
        return(out)
      
      curl::curl_download(url = x, destfile = out)
      
      return(out)
    }
  
  downloads <-
    raw_files %$%
    furrr::future_map2_chr(
      .x = request,
      .y = outfile,
      .f = dl_if_missing
    )
  
  # raw_files %$%
  #   curl::multi_download(
  #     urls = request,
  #     destfiles = outfile,
  #     resume = TRUE,
  #     multiplex = TRUE
  #   )
  
  out <-
    raw_files$outfile %>%
    magrittr::set_names(.,basename(.)) %>%
    furrr::future_map_dfr(
      # purrr::map_dfr(
      \(x){
        message("Reading: ", x)
        out_table <- 
          tryCatch(
            readxl::read_excel(x, col_types = "text"),
            error = \(e){NULL}
          )
        
        if(is.null(out_table)){
          warning("Failed to read: ", x)
        }
        
        return(out_table)
      }, 
      .id = "Source File")
  
  out %<>%
    dplyr::mutate(`Source File` = factor(`Source File`),
                  `State FSA Name` = factor(`State FSA Name`),
                  `County FSA Name` = factor(`County FSA Name`),
                  `Payment Date` = lubridate::as_date(as.numeric(`Payment Date`), origin = "1899-12-30"),
                  `Disbursement Amount` = as.numeric(`Disbursement Amount`),
                  `Accounting Program Year` = as.integer(`Accounting Program Year`),
                  `Accounting Program Description` = stringr::str_trim(stringr::str_squish(`Accounting Program Description`)),
                  `State FSA Code` = stringr::str_pad(`State FSA Code`, width = 2, side = "left", pad = "0"),
                  `County FSA Code` = stringr::str_pad(`County FSA Code`, width = 3, side = "left", pad = "0"),
                  `FSA Code` = factor(paste0(`State FSA Code`, `County FSA Code`)),
                  `Delivery Address Line` = ifelse(is.na(`Delivery Address Line`), `Delivery Address`, `Delivery Address Line`)
    ) %>%
    dplyr::select(
      `Accounting Program Year`,
      `State FSA Name`,
      `County FSA Name`,
      `FSA Code`,
      `Accounting Program Code`,
      `Accounting Program Description`,
      `Payment Date`,
      `Disbursement Amount`,
      `Formatted Payee Name`,
      `Address Information Line`,
      `Delivery Address Line`,
      `City Name`,
      `State Abbreviation`,
      `Zip Code`,
      `Delivery Point Bar Code`,
      `Source File`) %>%
    dplyr::arrange(`Accounting Program Year`,
                   `Accounting Program Code`,
                   `FSA Code`,
                   `County FSA Name`,
                   `State FSA Name`,
                   `Formatted Payee Name`)
  
  
  out %>%
    dplyr::group_by(`State FSA Name`,
                    `Accounting Program Year`) %>%
    arrow::write_dataset(
      path = "fsa-payment-files",
      format = "parquet",
      existing_data_behavior = "delete_matching",
      version = "latest",
      max_partitions = 4000L,
      max_open_files = 4000L,
      min_rows_per_group = 100000L
    )
  
  # keyring::key_set("aws_access_key_id")
  # keyring::key_set("aws_secret_access_key")
  # keyring::key_set("aws_session_token")
  
  aws_s3 <-
    paws::s3(credentials = 
               list(creds = list(
                 access_key_id = keyring::key_get("aws_access_key_id"),
                 secret_access_key = keyring::key_get("aws_secret_access_key"),
                 session_token = keyring::key_get("aws_session_token")
               )))
  
  uploads <-
    list.files("fsa-payment-files",
               full.names = TRUE,
               recursive = TRUE) %>%
    furrr::future_map(\(x){
      tryCatch(aws_s3$put_object(Bucket = "sustainable-fsa",
                                 Body = x,
                                 Key = x,
                                 ChecksumSHA256 = file(x) %>% 
                                   openssl::sha256() %>%
                                   openssl::base64_encode()),
               error = function(e){return(NULL)})
      
    },
    .options = furrr::furrr_options(seed = TRUE))
  
  plan(sequential)
  
}
