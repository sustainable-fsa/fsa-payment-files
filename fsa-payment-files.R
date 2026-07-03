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
    "future.mirai",
    "processx",
    "jsonlite",
    # Used by README.Rmd examples/rendering
    "arrow",
    "duckdb",
    "DBI",
    "glue"
  )
)

library(magrittr)
library(tidyverse)
library(furrr)
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
  
  ## ---- Sync to S3 ------------------------------------------------------
  ## Uses the AWS CLI (v2) with SSO credentials. Any failure stops the script.
  s3_bucket_name  <- "sustainable-fsa"
  s3_prefix       <- "fsa-payment-files"
  aws_profile     <- Sys.getenv("AWS_PROFILE", unset = "mco")
  cloudfront_base <- "https://data.sustainable-fsa.com"
  sync_dryrun     <- FALSE  # TRUE to preview uploads/deletes without changes

  sts <-
    processx::run("aws",
                  c("sts", "get-caller-identity",
                    "--profile", aws_profile),
                  error_on_status = FALSE)

  if (sts$status != 0)
    stop("AWS credentials unavailable for profile '", aws_profile,
         "'. Run: aws sso login --profile ", aws_profile)

  processx::run(
    "aws",
    c("s3", "sync",
      paste0(s3_prefix, "/"),
      paste0("s3://", s3_bucket_name, "/", s3_prefix, "/"),
      "--delete",
      "--exclude", "*.DS_Store",
      "--exclude", "_manifest.txt",
      if (sync_dryrun) "--dryrun",
      "--no-progress",
      "--profile", aws_profile),
    echo = TRUE)

  ## ---- Verify: S3 listing must exactly match local parquet files --------
  remote <-
    processx::run("aws",
                  c("s3api", "list-objects-v2",
                    "--bucket", s3_bucket_name,
                    "--prefix", paste0(s3_prefix, "/"),
                    "--output", "json",
                    "--profile", aws_profile))$stdout %>%
    jsonlite::fromJSON() %>%
    purrr::pluck("Contents") %>%
    tibble::as_tibble()

  remote_parquet <-
    remote %>%
    dplyr::filter(stringr::str_ends(Key, "\\.parquet"))

  remote_other <-
    remote %>%
    dplyr::filter(!stringr::str_ends(Key, "\\.parquet"),
                  Key != file.path(s3_prefix, "_manifest.txt"))

  local_parquet <-
    tibble::tibble(
      Key = list.files(s3_prefix,
                       recursive = TRUE,
                       full.names = TRUE,
                       pattern = "\\.parquet$")
    ) %>%
    dplyr::mutate(Size = file.size(Key))

  missing_remote <- setdiff(local_parquet$Key, remote_parquet$Key)
  extra_remote   <- setdiff(remote_parquet$Key, local_parquet$Key)
  size_mismatch  <-
    dplyr::inner_join(local_parquet, remote_parquet,
                      by = "Key", suffix = c(".local", ".s3")) %>%
    dplyr::filter(Size.local != Size.s3)

  if (length(missing_remote) > 0 || length(extra_remote) > 0 ||
      nrow(size_mismatch) > 0 || nrow(remote_other) > 0) {
    print(list(missing_remote = missing_remote,
               extra_remote = extra_remote,
               size_mismatch = size_mismatch,
               unexpected_nonparquet = remote_other$Key))
    stop("S3 sync verification FAILED: ",
         length(missing_remote), " missing remotely; ",
         length(extra_remote), " extraneous remotely; ",
         nrow(size_mismatch), " size mismatches; ",
         nrow(remote_other), " unexpected non-parquet objects.")
  }

  message("Sync verified: ", nrow(local_parquet),
          " parquet files match between local and s3://",
          s3_bucket_name, "/", s3_prefix, "/")

  ## ---- Manifest: one CloudFront URL per parquet object ------------------
  ## `=` must remain literal in these URLs: DuckDB's hive_partitioning
  ## detection parses `key=value` from the raw path.
  encode_key <-
    function(x){
      x %>%
        gsub("%", "%25", ., fixed = TRUE) %>% # must precede space encoding
        gsub(" ", "%20", ., fixed = TRUE)
    }

  manifest_file <- file.path(tempdir(), "_manifest.txt")

  remote_parquet$Key %>%
    sort() %>%
    encode_key() %>%
    paste0(cloudfront_base, "/", .) %>%
    writeLines(manifest_file)

  processx::run(
    "aws",
    c("s3", "cp",
      manifest_file,
      paste0("s3://", s3_bucket_name, "/", s3_prefix, "/_manifest.txt"),
      "--content-type", "text/plain",
      "--cache-control", "max-age=86400",
      "--profile", aws_profile),
    echo = TRUE)

  ## After an annual refresh, CloudFront edges may serve stale copies of
  ## re-uploaded keys for up to ~24 h. To force immediate consistency:
  ## aws cloudfront create-invalidation --distribution-id E1BNL6ONVN84RI \
  ##   --paths "/fsa-payment-files/*" --profile mco

  plan(sequential)

}
