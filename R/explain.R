#' @keywords internal
#' 
#' @useDynLib fastshap, .registration = TRUE
explain_column <- function(object, X, column, pred_wrapper, newdata = NULL) {
  
  # Check types
  if (!is.null(newdata) && !identical(class(X), class(newdata))) {
    stop("Arguments `X` and `newdata` do not inherit from the same class: ",
         "\n   * `X` inherits from class \"", class(X), "\"\n   * `newdata` ",
         "inherits from class \"", class(newdata), "\"", call. = FALSE)
  }
  
  # Find column position if feature name given
  if (is.character(column)) {
    column <- which(column == colnames(X))
  }
  
  # Extract dimensions of X (before possible subsetting)
  n <- nrow(X)  # number of training instances
  p <- ncol(X)  # number of features
  
  # Generate original and sampled feature instances
  if (is.null(newdata)) {
    W <- X[sample(n), ]  # shuffle rows
    O <- genOMat(n, p)
  } else {
    W <- X[sample(n, size = nrow(newdata)), , drop = FALSE]  # randomly sample rows from full X
    O <- genOMat(n, p)[sample(n, size = nrow(newdata)), , drop = FALSE]
    X <- newdata  # observations of interest
  }
  
  # Finish building logical matrix that resembles the random permutation order 
  # to use for each row of X and W (a TRUE indicates that the corresponding
  # feature appeared before the feature of interest in the associated 
  # permutation)
  O <- if (column == 1) {  # case 1
    cbind(TRUE, O)
  } else if (column == p) {  # case 2
    cbind(O, TRUE)
  } else {  # case 3
    cbind(  
      O[, 1:(column - 1), drop = FALSE], 
      TRUE, 
      O[, column:(p - 1), drop = FALSE]
    )
  }
  
  # Generate list of "Frankenstein" matrices (in one fell swoop). Essentially,
  # each rows in B[[1L]] and B[[2L]] is a combination of feature values from X
  # and W
  if (is.matrix(X)) {
    
    # Use RcppArmadillo for slight performance gain
    B <- genFrankensteinMatrices(X, W, O, feature = column)
    colnames(B[[1L]]) <- colnames(B[[2L]]) <- colnames(X)

  } else {
    
    # Use base R's logical subsetting
    B <- list(X, X)
    B[[1L]][O] <- X[O]
    B[[1L]][!O] <- W[!O]
    O[, column] <- FALSE
    B[[2L]][O] <- X[O]
    B[[2L]][!O] <- W[!O]
    
  }
  
  # Return differences in predictions
  pred_wrapper(object, newdata = B[[1L]]) - 
    pred_wrapper(object, newdata = B[[2L]])  
  
}


#' Fast approximate Shapley values
#' 
#' Compute fast (approximate) Shapley values for a set of features.
#' 
#' @param object A fitted model object (e.g., a 
#' \code{\link[randomForest]{randomForest}} object).
#'
#' @param feature_names Character string giving the names of the predictor
#' variables (i.e., features) of interest. If \code{NULL} (default) they will be
#' taken from the column names of \code{X}.
#'
#' @param X A matrix-like R object (e.g., a data frame or matrix) containing 
#' ONLY the feature columns from the training data.
#'
#' @param pred_wrapper Prediction function that requires two arguments,
#' \code{object} and \code{newdata}. The output of this function should be 
#' determined according to:
#'
#' \describe{
#'   \item{Regression}{A numeric vector of predicted outcomes.}
#'   \item{Binary classification}{A vector of predicted class probabilities
#'   for the reference class.}
#'   \item{Multiclass classification}{A vector of predicted class probabilities
#'   for the reference class.}
#' }
#' 
#' @param nsim The number of Monte Carlo repetitions to use for estimating each 
#' Shapley value. Default is 1.
#' 
#' @param newdata A matrix-like R object (e.g., a data frame or matrix) 
#' containing ONLY the feature columns for the observation(s) of interest. 
#' Default is \code{NULL} which will produce approximate Shapley values for all 
#' the rows in \code{X}.
#' 
#' @param ... Additional optional arguments to be passed onto
#' \code{\link[plyr]{laply}}.
#' 
#' @return A tibble with one column for each feature specified in 
#' \code{feature_names} (if \code{feature_names = NULL}, the default, there will
#' be one column for each feature in \code{X}) and one row for each observation
#' in \code{newdata} (if \code{newdata = NULL}, the default, there will be one
#' row for each observation in \code{X}). 
#' 
#' @seealso You can find more examples (with larger and more realistic data 
#' sets) on the \strong{fastshap} GitHub repository: 
#' \url{https://github.com/bgreenwell/fastshap}.
#' 
#' 
#' @export
#' 
#' @examples 
#' #
#' # A projection pursuit regression (PPR) example
#' #
#' 
#' # Load the sample data; see ?datasets::mtcars for details
#' data(mtcars)
#' 
#' # Fit a projection pursuit regression model
#' mtcars.ppr <- ppr(mpg ~ ., data = mtcars, nterms = 1)
#' 
#' # Compute approximate Shapley values using 10 Monte Carlo simulations
#' set.seed(101)  # for reproducibility
#' shap <- explain(mtcars.ppr, X = subset(mtcars, select = -mpg), nsim = 10, 
#'                 pred_wrapper = predict)
#' shap
#' 
#' # Shapley-based plots
#' library(ggplot2)
#' autoplot(shap)  # Shapley-based importance plot
#' autoplot(shap, type = "dependence", feature = "wt", X = mtcars)
#' autoplot(shap, type = "contribution", row_num = 1)  # explain first row of X
explain <- function(object, feature_names = NULL, X, nsim = 1, pred_wrapper,
                     newdata = NULL, ...) {
  
  # TODO:
  #
  #   1. Correct sum of SHAP values to equal the predicted output of the model
  #      minus the average prediction?
  #
  #   2. Feature grouping. For assessing the importance of groups of features
  #      without assuming independence between them; see
  #      https://github.com/slundberg/ShapleyValues.jl for an implementation in
  #      Julia.
  
  if (is.null(feature_names)) {
    feature_names = colnames(X)
  }
  res <- plyr::laply(feature_names, .fun = function(x) {
    reps <- replicate(nsim, {  # replace later with vapply()
      explain_column(object, X = X, column = x, pred_wrapper = pred_wrapper,
                     newdata = newdata)  # numeric(nrow(X))
    })
    res <- if (is.matrix(reps)) {
      # apply(reps, MARGIN = 1, FUN = mean)
      rowMeans(reps)
    } else {
      mean.default(reps)
    }
  }, ...)
  res <- if (length(feature_names) == 1L) {
    tibble::enframe(res, name = NULL)
  } else {
    res <- tibble::as_tibble(t(res))
  }
  names(res) <- feature_names
  class(res) <- c(class(res), "explain")
  res
}
