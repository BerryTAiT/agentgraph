# PII scrubbing (standalone helper) -------------------------------------------
#
# `pii_scrub()` redacts common PII from text before it leaves the process.
# It is a heuristic, non-cryptographic scrubber: patterns are applied in a
# canonical order (email -> API key -> private key -> JWT -> AWS secret ->
# US SSN -> credit-card-like digits -> US phone -> IPv4) so a broader pattern
# never partially redacts something a more specific pattern would have caught
# first. The same patterns and order are used by the transparent
# `provider_pii()` filter in the C++ engine.

.pii_patterns <- c(
  email       = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
  api_key     = "\\b(?:sk|pk|rk|ghp|gho|ghu|ghs|ghr|AKIA|AIza)[A-Za-z0-9_\\-]{16,}\\b",
  private_key = "-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY(?: BLOCK)?-----",
  jwt         = "\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b",
  aws_secret  = "\\b[A-Za-z0-9/+=]{40}\\b",
  ssn         = "\\b[0-9]{3}-[0-9]{2}-[0-9]{4}\\b",
  credit_card = "\\b(?:[0-9][ -]?){12,18}[0-9]\\b",
  phone       = "(?:\\+?1[-.\\s]?)?\\(?[0-9]{3}\\)?[-.\\s]?[0-9]{3}[-.\\s]?[0-9]{4}",
  ipv4        = "\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b"
)

.pii_canonical <- names(.pii_patterns)

#' Redact common PII from text
#'
#' Replaces email addresses, API keys, PEM private-key headers, JWTs, AWS
#' secret-access-key-shaped strings, US Social Security numbers, credit-card
#' numbers, US phone numbers, and IPv4 addresses with `redact`. Pass `entities`
#' to restrict which are scrubbed; any subset of \code{"email"},
#' \code{"api_key"}, \code{"private_key"}, \code{"jwt"}, \code{"aws_secret"},
#' \code{"ssn"}, \code{"credit_card"}, \code{"phone"}, \code{"ipv4"}.
#' Processing always follows a canonical order regardless of the order in
#' `entities`, so a 16-digit card number is redacted as one unit rather than
#' being partially consumed by the phone-number pattern.
#'
#' @param text A character vector of strings to scrub
#' @param redact Replacement text (default "\[REDACTED\]")
#' @param entities Character vector naming which entity types to scrub
#' @return A character vector of the same length as `text`
#' @export
pii_scrub <- function(text, redact = "[REDACTED]",
                      entities = c("email", "api_key", "private_key", "jwt",
                                   "aws_secret", "ssn", "credit_card",
                                   "phone", "ipv4")) {
  if (!is.character(text)) {
    stop("pii_scrub(): `text` must be a character vector.")
  }
  if (!is.character(redact) || length(redact) != 1L || is.na(redact)) {
    stop("pii_scrub(): `redact` must be a single non-NA string.")
  }
  entities <- match.arg(entities, .pii_canonical, several.ok = TRUE)

  vapply(text, function(x) {
    out <- x
    for (e in .pii_canonical) {
      if (e %in% entities) {
        out <- gsub(.pii_patterns[[e]], redact, out, perl = TRUE)
      }
    }
    out
  }, character(1L), USE.NAMES = FALSE)
}
