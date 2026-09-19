# Voice pipeline (STT / TTS) --------------------------------------------------
#
# transcribe() sends audio to a Whisper-compatible endpoint; synthesize() sends
# text to an ElevenLabs-compatible TTS endpoint; voice_run() chains
# audio -> STT -> graph -> TTS -> audio. Audio *input* parts already exist
# (audio_part()); this completes the loop. HTTP uses curl (Suggests).

#' Create a Whisper (STT) provider configuration
#'
#' @param api_key API key (or set OPENAI_API_KEY env var)
#' @param model Transcription model
#' @param base_url Base URL of the transcriptions API
#' @return An STT provider configuration list
#' @export
provider_whisper <- function(api_key = Sys.getenv("OPENAI_API_KEY"),
                             model = "whisper-1",
                             base_url = "https://api.openai.com/v1") {
  list(name = "whisper", api_key = api_key, model = model, base_url = base_url)
}

#' Create an ElevenLabs (TTS) provider configuration
#'
#' @param api_key API key (or set ELEVENLABS_API_KEY env var)
#' @param voice_id The ElevenLabs voice ID (required to synthesize)
#' @param model TTS model
#' @param base_url Base URL of the TTS API
#' @return A TTS provider configuration list
#' @export
provider_elevenlabs <- function(api_key = Sys.getenv("ELEVENLABS_API_KEY"),
                                voice_id = NULL,
                                model = "eleven_multilingual_v2",
                                base_url = "https://api.elevenlabs.io/v1") {
  list(name = "elevenlabs", api_key = api_key, voice_id = voice_id,
       model = model, base_url = base_url)
}

#' Transcribe audio to text (speech-to-text)
#'
#' Sends an audio file to a Whisper-compatible `POST /audio/transcriptions`
#' endpoint (multipart) and returns the transcript text.
#'
#' @param audio_file Path to an audio file
#' @param provider An STT provider (from [provider_whisper()])
#' @param language Optional language code
#' @return The transcript text
#' @export
transcribe <- function(audio_file, provider = provider_whisper(), language = NULL) {
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop("transcribe(): requires the 'curl' package.")
  }
  if (!is.character(audio_file) || length(audio_file) != 1L || !file.exists(audio_file)) {
    stop("transcribe(): `audio_file` must be an existing file.")
  }
  h <- curl::new_handle(useragent = "agentgraph")
  curl::handle_setform(h, file = curl::form_file(audio_file), model = provider$model)
  if (!is.null(language)) curl::handle_setform(h, language = language)
  if (is.character(provider$api_key) && nzchar(provider$api_key)) {
    curl::handle_setopt(h, httpheader = paste0("Authorization: Bearer ", provider$api_key))
  }
  url <- paste0(sub("/+$", "", provider$base_url), "/audio/transcriptions")
  r <- curl::curl_fetch_memory(url, handle = h)
  if (r$status_code >= 400L) stop("transcribe(): HTTP ", r$status_code, " from ", url)
  j <- jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE)
  as.character(j$text)[1L]
}

#' Synthesize text to speech (text-to-speech)
#'
#' Sends text to an ElevenLabs-compatible `POST /text-to-speech/<voice_id>`
#' endpoint and writes the returned audio to a file.
#'
#' @param text The text to synthesize
#' @param provider A TTS provider (from [provider_elevenlabs()])
#' @param output_file Destination audio file (defaults to a temp file)
#' @return The audio file path
#' @export
synthesize <- function(text, provider = provider_elevenlabs(), output_file = NULL) {
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop("synthesize(): requires the 'curl' package.")
  }
  if (is.null(provider$voice_id) || !nzchar(provider$voice_id)) {
    stop("synthesize(): `provider` must have a `voice_id` (use provider_elevenlabs(voice_id = ...)).")
  }
  if (is.null(output_file)) output_file <- tempfile(fileext = ".mp3")
  body <- jsonlite::toJSON(list(text = as.character(text)[1L]), auto_unbox = TRUE)
  h <- curl::new_handle(useragent = "agentgraph")
  curl::handle_setopt(h, post = TRUE, postfields = body, customrequest = "POST")
  headers <- "Content-Type: application/json"
  if (is.character(provider$api_key) && nzchar(provider$api_key)) {
    headers <- c(headers, paste0("xi-api-key: ", provider$api_key))
  }
  curl::handle_setopt(h, httpheader = headers)
  url <- paste0(sub("/+$", "", provider$base_url), "/text-to-speech/", provider$voice_id)
  r <- curl::curl_fetch_memory(url, handle = h)
  if (r$status_code >= 400L) stop("synthesize(): HTTP ", r$status_code, " from ", url)
  writeBin(r$content, output_file)
  output_file
}

#' Run a graph through a voice loop (STT -> agent -> TTS)
#'
#' Transcribes `audio_file` (when given) to text, runs `graph` on that text,
#' and synthesizes the final answer back to audio. Returns the intermediate
#' text, the answer, the audio file path, and the graph state.
#'
#' @param graph A graph (from [state_graph()])
#' @param state Initial state (or NULL to use `text`)
#' @param text Input text (skips STT when given)
#' @param audio_file Optional input audio (transcribed when given)
#' @param stt_provider An STT provider (required when `audio_file` is given)
#' @param tts_provider Optional TTS provider (skips TTS when NULL)
#' @param output_file Optional audio output path
#' @param ... Extra arguments forwarded to [run()]
#' @return A list with `text`, `answer`, `audio`, and `state`
#' @export
voice_run <- function(graph, state = NULL, text = NULL, audio_file = NULL,
                      stt_provider = NULL, tts_provider = NULL,
                      output_file = NULL, ...) {
  if (!is.null(audio_file)) {
    if (is.null(stt_provider)) {
      stop("voice_run(): provide `stt_provider` when `audio_file` is given.")
    }
    text <- transcribe(audio_file, stt_provider)
  }
  if (!is.null(text)) {
    if (is.list(state) && !is.null(state$messages)) {
      state$messages <- c(state$messages, list(user_msg(text)))
    } else {
      state <- list(messages = list(user_msg(text)))
    }
  }
  result <- run(graph, state = state, ...)
  answer <- final_answer(result)
  audio <- if (is.null(tts_provider)) NULL else synthesize(answer, tts_provider, output_file)
  list(text = text, answer = answer, audio = audio, state = result)
}
