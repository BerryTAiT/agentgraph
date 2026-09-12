#' Define a tool for use in agent graphs
#'
#' @param name Tool name (used by LLM to reference the tool)
#' @param description Description of what the tool does
#' @param parameters A list of parameter definitions
#' @param handler An R function that executes the tool
#' @return A tool definition list
#' @export
tool <- function(name, description, parameters = list(), handler) {
  properties <- list()
  required <- character(0)
  for (pname in names(parameters)) {
    p <- parameters[[pname]]
    properties[[pname]] <- p$schema
    if (isTRUE(p$required)) required <- c(required, pname)
  }

  # `properties` must serialize as a JSON object and `required` as a JSON
  # array. jsonlite's auto_unbox would otherwise turn an empty properties list
  # into `[]` and a single-element required into a bare string, both of which
  # violate the OpenAI function-calling schema.
  if (length(properties) == 0) {
    properties_json <- "{}"
  } else {
    properties_json <- jsonlite::toJSON(properties, auto_unbox = TRUE)
  }
  required_json <- jsonlite::toJSON(required)

  list(
    name = name,
    description = description,
    parameters = parameters,
    parameters_json = paste0(
      '{"type":"object","properties":', properties_json,
      ',"required":', required_json, '}'
    ),
    handler = handler
  )
}

#' Define a string parameter
#' @param description Parameter description
#' @param required Whether the parameter is required
#' @return A parameter definition
#' @export
param_string <- function(description, required = TRUE) {
  list(schema = list(type = "string", description = description),
       required = required)
}

#' Define a number parameter
#' @param description Parameter description
#' @param required Whether the parameter is required
#' @return A parameter definition
#' @export
param_number <- function(description, required = TRUE) {
  list(schema = list(type = "number", description = description),
       required = required)
}

#' Define an integer parameter
#' @param description Parameter description
#' @param required Whether the parameter is required
#' @return A parameter definition
#' @export
param_integer <- function(description, required = TRUE) {
  list(schema = list(type = "integer", description = description),
       required = required)
}

#' Define a boolean parameter
#' @param description Parameter description
#' @param required Whether the parameter is required
#' @return A parameter definition
#' @export
param_boolean <- function(description, required = TRUE) {
  list(schema = list(type = "boolean", description = description),
       required = required)
}

#' Define an enum parameter
#' @param description Parameter description
#' @param values Allowed values
#' @param required Whether the parameter is required
#' @return A parameter definition
#' @export
param_enum <- function(description, values, required = TRUE) {
  list(schema = list(type = "string", description = description, enum = values),
       required = required)
}

#' Define an object parameter
#' @param description Parameter description
#' @param properties Named list of property definitions
#' @param required Whether the parameter is required
#' @return A parameter definition
#' @export
param_object <- function(description, properties = list(), required = TRUE) {
  if (length(properties) == 0) properties <- setNames(list(), character(0))
  list(schema = list(type = "object", description = description,
                     properties = properties),
       required = required)
}
