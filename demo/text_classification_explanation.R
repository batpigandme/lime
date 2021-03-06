library(stringi)
library(lime)
library(text2vec)
library(data.table)
library(magrittr)
library(purrr)
library(xgboost)

set.seed(2000)

# Data loading
data("train_sentences")
data("test_sentences")
data("stop_words_sentences")

label_to_explain <- "OWNX"

# label train set and test set
train_sentences[, label := class.text == label_to_explain]
test_sentences[, label := class.text == label_to_explain]

get.iterator <- function(data) itoken(data, preprocess_function = tolower, tokenizer = word_tokenizer, progressbar = F)

# Extract vocabulary
v <-  create_vocabulary(get.iterator(train_sentences$text), stopwords = stop_words_sentences)

# Function to transform text in matrix
get.matrix <- function(data) {
  i <- get.iterator(data)
  create_dtm(i, vocab_vectorizer(v))
}

lsa.full.text <- LSA$new(n_topics = 100)
tfidf <- TfIdf$new()
get.matrix(train_sentences$text) %>% fit(tfidf)
get.matrix(train_sentences$text) %>% transform(tfidf) %>% fit(lsa.full.text)

add.lsa <- function(m, lsa) {
  l <- transform(m, lsa)
  colnames(l) <- ncol(l) %>% seq() %>% paste0("lsa.", .)
  cbind2(m, l)
}

dtrain <- get.matrix(train_sentences$text) %>% transform(tfidf) %>% add.lsa(lsa.full.text) %>% xgb.DMatrix(label = train_sentences$label)
dtest <-  get.matrix(test_sentences$text) %>% transform(tfidf) %>% add.lsa(lsa.full.text) %>% xgb.DMatrix(label = test_sentences$label)

watchlist <- list(eval = dtest)
param <- list(max_depth = 7, eta = 0.1, objective = "binary:logistic", eval_metric = "error", nthread = 1)
bst <- xgb.train(param, dtrain, nrounds = 500, watchlist, early_stopping_rounds = 100)

test_sentences[,prediction := predict(bst, dtest, type = "prob") > 0.5]
test_sentences[label == T, sum(label != prediction)]
test_sentences[label == T, sum(label == prediction)]
test_sentences[, sum(label == prediction)/length(label)]
test_sentences[, mean(label)]

get.features.matrix <- . %>%
  get.matrix() %>%
  transform(tfidf) %>%
  add.lsa(lsa.full.text) %>%
  xgb.DMatrix()

# use currying to make the function work in one call
system.time(results <- lime(test_sentences[label == T][4:6, text], bst, get.features.matrix, n_labels = 1, number_features_explain = 2, keep_word_position = FALSE)() %T>%
  print)

long_document <- test_sentences[label == T][5, text] %>% rep(50) %>% paste(collapse = " ")
system.time(lime(long_document, bst, get.features.matrix, n_labels = 1, number_features_explain = 2, keep_word_position = TRUE, n_permutations = 5e3, feature_selection_method = "highest_weights")() %>%
  print)


permutation_cases <- lime:::permute_cases.character(long_document, 5e3, tokenization = lime::default_tokenize, keep_word_position = TRUE)
predicted_labels_dt <- get.features.matrix(permutation_cases$permutations) %>% lime::default_predict(model = bst)

learn <- function(depth, rounds) {
  bst.bow <- xgb.train(list(max_depth = depth, eta = 1, silent = 1, objective = "binary:logistic"), m, nrounds = rounds)
  if (sum(stri_count_regex(xgb.dump(bst.bow), "yes=(\\d+),no=(\\d+)")) == 0) learn(depth, rounds + 1) else bst.bow
}

names(predicted_labels_dt) %>% map(~ {
  column_name <- .
  m <- xgb.DMatrix(permutation_cases$tabular, label = predicted_labels_dt[[column_name]], weight = permutation_cases$permutation_distances)
  bst.bow <- learn(2, 1)
  xgb.importance(model = bst.bow) %>%
    dplyr::mutate(Feature = permutation_cases$tokens[as.numeric(Feature) + 1],
           Label = column_name) %>%
    dplyr::select("Label", dplyr::everything())
  }) %>%
  dplyr::bind_rows()

