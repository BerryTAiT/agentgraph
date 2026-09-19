# Forwarder for the Streamly subscription agent.
#
# The R console's working directory keeps resetting to the repo root between
# sessions, which broke `source("main.R")` (the real script lives in
# subscription-agent/). This forwarder makes the user's habitual command work
# from the repo root (and anywhere else, via the absolute fallback):
#
#   source("main.R")
#
candidates <- c(
  file.path("subscription-agent", "main.R"),                        # launched from the repo root
  "c:/Users/berry/Desktop/langgraphc++/subscription-agent/main.R"   # absolute fallback
)
hit <- candidates[file.exists(candidates)]
if (length(hit) == 0) {
  stop("Cannot find subscription-agent/main.R from working directory: ", getwd())
}
source(hit[1])
