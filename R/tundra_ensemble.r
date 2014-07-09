#' Tundra ensemble wrapper

# return a tundra container for the ensemble submodels
fetch_submodel_container <- function(type, model_parameters) {

  stopifnot(is.character(type))

  # additional munge steps for submodel (empty list means use the post-munged data without additional work)
  mungeprocedure <- model_parameters$data %||% list() 

  # remaining model parameters (default_args)
  default_args <- model_parameters[which(names(model_parameters) != 'data')] %||% list()

  # internal argument
  internal <- list()

  # look for associated tundra container
  if (exists(model_fn <- paste0('tundra_', type))) {
    return(get(model_fn)(mungeprocedure, default_args))
  } 

  # look for associated classifier
  prefilename <- file.path(syberia_root(), 'lib', 'classifiers', type)
  if ((file.exists(filename <- paste0(prefilename, '.r')) ||
       file.exists(filename <- paste0(prefilename, '.R')))) {
  
    provided_env <- new.env()
    source(filename, local = provided_env)
    provided_functions <- syberiaStages:::parse_custom_classifier(provided_env, type)

    # create a new tundra container on the fly
    my_tundra_container <-
      tundra:::tundra_container$new(type, 
                                    provided_functions$train, provided_functions$predict,
                                    mungeprocedure, default_args, internal)
    return(my_tundra_container)

  }
  
  stop("Missing tundra container for keyword '", type, "'. ",
       "It must exist in the tundra package or be present in ",
       paste0("lib/classifiers/", type, ".R"), call. = FALSE)

}

# train sub models and master model
tundra_ensemble_train_fn <- function(dataframe) {

  stopifnot('submodels' %in% names(input) && 'master' %in% names(input))

  # Set defaults for other parameters
  resample <- input$resample %||% FALSE         # whether or not to use bootstrapped replicates of the data
  replicates <- input$replicates %||% 3         # how many bootstrapped replicates to use if resample = T
  buckets <- input$validation_buckets %||% 10   # number of cross validation folds
  seed <- input$seed %||% 0                     # seed controls the sampling for cross validation

  # Set up 
  cat("Training ensemble composed of ", length(input$submodels), " submodels...\n", sep='')
  if (seed != 0) set.seed(seed) # set seed 

##  use_cache <- 'cache_dir' %in% names(input)
##  if (use_cache) {
##    stopifnot(is.character(input$cache_dir))
##    input$cache_dir <- normalizePath(input$cache_dir)
##  }
  
  # Remove munge procedure from data.frame
  # so that it does not get attached to the model tundraContainer.
  attr(dataframe, 'mungepieces') <- NULL

  # cross-validation buckets
  if (nrow(dataframe) < buckets) stop('Dataframe too small')
  slices <- split(1:nrow(dataframe), sample.int(buckets, nrow(dataframe), replace=T)) 

  if (resample) {

    packages('parallel')
    
    # make a list to store submodels
    output <<- list()
    output$submodels <<- list()
    
    # parallelize if possible
    apply_method_name <- if (suppressWarnings(require(pbapply))) 'pblapply' else 'lapply'
    apply_method <- get(apply_method_name)
    
    # We have to compute along submodels rather than along slices, because
    # we are expecting to resample differently for each submodel. Hence,
    # it would not make sense to recombine resulting predictions row-wise,
    # only column-wise.
    which_submodel <- 0
    
    # get predictions on the bootstrapped data
    # use CV predictions if for rows in the bootstrap sample
    # use predictions from a model built on entire bootstrap sample for not-in-sample rows
    get_bootstrap_preds <- function(model_parameters) {
      
      which_submodel <<- which_submodel + 1
      
      ##if (use_cache) {
      ##  cache_path <- paste0(input$cache_dir, '/', which_submodel)
      ##  if (file.exists(tmp <- paste0(cache_path, 'p')))
      ##    return(as.numeric(as.character(readRDS(tmp)[seq_len(nrow(dataframe))])))
      ##}
      
      # create a bootstrap replication of the postmunged dataframe
      # this should occur BEFORE munging to avoid biasing the CV error
      selected_rows <- sample.int(nrow(dataframe),replace=T)
      bs_dataframe <- dataframe[selected_rows,]
      attr(bs_dataframe, "selected_rows") <- selected_rows
      
      # Sneak the munge procedure out of the submodel, because we do not
      # want to re-run it many times during n-fold cross-validation.
      munge_procedure <- model_parameters$data %||% list()
      model_parameters$data <- NULL
      
      # After the line below, attr(sub_df, 'selected_rows') will have the resampled
      # row numbers relative to the original dataframe.
      sub_df <- munge(bs_dataframe, munge_procedure)

      # Fetch the tundra container for this submodel
      output$submodels[[which_submodel]] <<- fetch_submodel_container(model_parameters[[1]],model_parameters[-1])
      
      # Train model on all slices but one, predict on remaining slice
      cv_predict <- function(rows) {
        # Train submodel on all but the current validation slice.
        output$submodels[[which_submodel]]$train(sub_df[-rows, ], verbose = TRUE)
        # Mark untrained so tundra container allows us to train again next iteration.
        on.exit(output$submodels[[which_submodel]]$trained <<- FALSE)
        # predict on the remaining rows not used for training
        output$submodels[[which_submodel]]$predict(sub_df[rows,])
      }
      
      # Generate predictions for the resampled dataframe using n-fold
      # cross-validation (and keeping in mind the above comment, note we
      # are not re-sampling multiple times, which would be erroneous).
      cv_predictions <- do.call(c, mclapply(slices, cv_predict))

      # Most of the work is done. We now have to generate predictions by
      # training the model on the whole resampled dataframe, and predicting
      # on the rows that were left out due to resampling to train our meta learner later.
      output$submodels[[which_submodel]]$train(sub_df, verbose = TRUE)
      #if (use_cache) saveRDS(output$submodels[[which_submodel]], cache_path)
      
      # Record what row indices were left out due to resampling.
      remaining_rows <- setdiff(seq_len(nrow(dataframe)), attr(sub_df, 'selected_rows'))

      # Get the predictions for these remaining rows
      if (length(remaining_rows)>0) {
        rest_of_predictions <- 
          output$submodels[[which_submodel]]$predict(sub_df[remaining_rows,])
      } else {
        rest_of_predictions <- c()
      }
      predictions <- append(cv_predictions,rest_of_predictions)

      # Trick: since we have already done all the hard work of predicting,
      # we can now just append the remaining rows to the sampled rows (with duplicates)
      # and find a sequence parameterizing 1, 2, ..., nrow(dataframe) within
      # this list. For example, if 
      #   selected_rows <- c(2, 2, 4, 5, 4)
      # and 
      #   remaining_rows <- c(1, 3)
      # then 
      #   combined_rows <- c(6, 1, 7, 3, 4)
      # which are indices corresponding to a sequence c(1, 2, 3, 4, 5)
      # inside of c(selected_rows, remaining_rows) = c(2, 2, 4, 5, 4, 1, 3)
      rows_drawer <- append(attr(sub_df, 'selected_rows'), remaining_rows)
      combined_rows <- vapply(seq_len(nrow(dataframe)), 
                              function(x) which(x == rows_drawer)[1], integer(1))

      # Now that we have computed a sequence of indices parametrizing 1 .. nrow(dataframe)
      # through c(selected_rows, remaining_rows), take the respective predicted
      # scores and grab the relative indices in that order.
      #if (use_cache) saveRDS(predicts[combined_rows], paste0(cache_path, 'p'))
      predictions[combined_rows]   
    }
    
    # Replicate the submodel list
    submodel_list <- rep(input$submodels, each=replicates)
    names(submodel_list) <- paste0(names(submodel_list),'_',1:replicates)
    
    # Get predictions over all submodels
    suppressMessages(
      metalearner_dataframe <- do.call(cbind, apply_method(submodel_list, get_bootstrap_preds))
    )
    colnames(metalearner_dataframe) <- names(submodel_list)
    print(metalearner_dataframe)
    
  } else {

    # function to train on K-1 buckets, predict on 1 holdout bucket
    cv_predict <- function(model_parameters, rows) {

      # get the submodel tundra container
      model <- fetch_submodel_container(model_parameters[[1]],model_parameters[-1])

      # omit the rows in this bucket and train the submodel
      model$train(dataframe[-rows, ], verbose = TRUE)

      # get predictions on the holdout data 
      sub_df <- dataframe[rows,]
      res <- model$predict(sub_df)

    }

    # returns a data.frame that contains the predictions on this bucket for all submodels
    # each column in the sub_df dataframe contains the predictions on this bucket for all submodels
    cv_predict_all_models <- function(rows) {
      sub_df <- data.frame(lapply(input$submodels, cv_predict, rows))
      colnames(sub_df) <- paste0("submodel", seq_along(sub_df))
      sub_df
    }

    # get the cross validated scores for all observations and all submodels
    metalearner_dataframe <- do.call(rbind, lapply(slices, cv_predict_all_models))

  }

  rownames(metalearner_dataframe) <- NULL
  metalearner_dataframe <- data.frame(metalearner_dataframe, stringsAsFactors = FALSE)
  colnames(metalearner_dataframe) <- paste0("model", seq_along(metalearner_dataframe))
  metalearner_dataframe$dep_var <- dataframe$dep_var
  if (use_cache)
    saveRDS(metalearner_dataframe, paste0(input$cache_dir, '/metalearner_dataframe'))

  output$master <<- fetch_submodel_container(input$master[[1]],input$master[-1])
  output$master$train(metalearner_dataframe, verbose = TRUE)

  # Train final submodels
  if (!resample) { # If resampling was used, submodels are already trained
    output$submodels <<- lapply(input$submodels, function(model_parameters) {
      model <- fetch_submodel_container(model_parameters[[1]],model_parameters[-1])
      model$train(dataframe, verbose = TRUE)
      model
    })
  }

  invisible("ensemble")
}

tundra_ensemble_predict_fn <- function(dataframe, predicts_args = list()) {
  meta_dataframe <- data.frame(lapply(output$submodels, function(model) {
    model$predict(dataframe[, which(colnames(dataframe) != 'dep_var')])
  }))
  colnames(meta_dataframe) <- paste0("model", seq_along(meta_dataframe))
  print(meta_dataframe)
  cat("\n\n")

  output$master$predict(meta_dataframe)
}

#' @export
tundra_ensemble <- function(munge_procedure = list(), default_args = list(), internal = list()) {
  tundra:::tundra_container$new('ensemble',
                       tundra_ensemble_train_fn,
                       tundra_ensemble_predict_fn,
                       munge_procedure,
                       default_args,
                       internal)
}
