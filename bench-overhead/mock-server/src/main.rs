//! Deterministic mock LLM server for benchmarking client measurement overhead.
//!
//! Emits SSE tokens at precisely controlled intervals so that the "ground truth"
//! TTFT and ITL are known. Comparing client-measured values against these reveals
//! how much overhead the client introduces.

use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::State;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Json};
use axum::routing::{get, post};
use axum::Router;
use clap::Parser;
use futures::stream::Stream;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

#[derive(Parser, Debug, Clone)]
#[command(name = "mock-llm-server")]
struct Cli {
    /// Port to listen on.
    #[arg(long, default_value_t = 8089)]
    port: u16,

    /// Interval between token emissions in milliseconds (e.g. 10 → 100 tok/s).
    #[arg(long, default_value_t = 10)]
    token_interval_ms: u64,

    /// Delay before the first token in milliseconds (simulates prefill).
    #[arg(long, default_value_t = 50)]
    first_token_delay_ms: u64,

    /// Default number of output tokens per request (overridden by max_tokens in body).
    #[arg(long, default_value_t = 100)]
    num_tokens: usize,
}

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct AppState {
    token_interval: Duration,
    first_token_delay: Duration,
    default_num_tokens: usize,
}

// ---------------------------------------------------------------------------
// Request / response types
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct CompletionRequest {
    #[allow(dead_code)]
    model: Option<String>,
    #[allow(dead_code)]
    prompt: Option<serde_json::Value>,
    max_tokens: Option<usize>,
    #[allow(dead_code)]
    stream: Option<bool>,
    // Ignore all other fields (repetition_penalty, ignore_eos, etc.)
}

#[derive(Deserialize)]
struct ChatCompletionRequest {
    #[allow(dead_code)]
    model: Option<String>,
    #[allow(dead_code)]
    messages: Option<serde_json::Value>,
    max_completion_tokens: Option<usize>,
    max_tokens: Option<usize>,
    #[allow(dead_code)]
    stream: Option<bool>,
}

#[derive(Deserialize)]
struct TokenizeRequest {
    #[allow(dead_code)]
    model: Option<String>,
    prompt: Option<String>,
}

#[derive(Deserialize)]
struct DetokenizeRequest {
    #[allow(dead_code)]
    model: Option<String>,
    tokens: Option<Vec<u64>>,
}

#[derive(Serialize)]
struct ModelsResponse {
    data: Vec<ModelEntry>,
}

#[derive(Serialize)]
struct ModelEntry {
    id: String,
    root: String,
    object: String,
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /v1/models — static model list
async fn models() -> Json<ModelsResponse> {
    Json(ModelsResponse {
        data: vec![ModelEntry {
            id: "mock-model".into(),
            root: "mock-model".into(),
            object: "model".into(),
        }],
    })
}

/// POST /v1/completions — SSE streaming completions
async fn completions(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CompletionRequest>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let num_tokens = payload.max_tokens.unwrap_or(state.default_num_tokens);
    let prompt_tokens = estimate_prompt_tokens(&payload.prompt);
    let req_id = uuid::Uuid::new_v4().to_string();
    let first_delay = state.first_token_delay;
    let interval_dur = state.token_interval;

    let stream = async_stream::stream! {
        // Simulate prefill delay
        tokio::time::sleep(first_delay).await;

        // Emit tokens at precise intervals
        let mut interval = tokio::time::interval(interval_dur);
        // First tick fires immediately after the sleep above
        interval.tick().await;

        for i in 0..num_tokens {
            // Token chunk
            let data = serde_json::json!({
                "id": format!("cmpl-{req_id}"),
                "object": "text_completion",
                "choices": [{
                    "text": format!(" tok{i}"),
                    "index": 0,
                    "finish_reason": serde_json::Value::Null,
                }],
            });
            yield Ok(Event::default().data(data.to_string()));

            // Wait for next interval (skip for last token — usage follows immediately)
            if i < num_tokens - 1 {
                interval.tick().await;
            }
        }

        // Usage summary chunk (with empty choices, matching vLLM format)
        let usage_data = serde_json::json!({
            "id": format!("cmpl-{req_id}"),
            "object": "text_completion",
            "choices": [],
            "usage": {
                "completion_tokens": num_tokens,
                "prompt_tokens": prompt_tokens,
                "total_tokens": num_tokens + prompt_tokens,
            },
        });
        yield Ok(Event::default().data(usage_data.to_string()));

        // Done sentinel
        yield Ok(Event::default().data("[DONE]"));
    };

    Sse::new(stream).keep_alive(KeepAlive::default())
}

/// POST /v1/chat/completions — SSE streaming chat completions
async fn chat_completions(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ChatCompletionRequest>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let num_tokens = payload
        .max_completion_tokens
        .or(payload.max_tokens)
        .unwrap_or(state.default_num_tokens);
    let prompt_tokens = 32; // Fixed for chat
    let req_id = uuid::Uuid::new_v4().to_string();
    let first_delay = state.first_token_delay;
    let interval_dur = state.token_interval;

    let stream = async_stream::stream! {
        tokio::time::sleep(first_delay).await;

        let mut interval = tokio::time::interval(interval_dur);
        interval.tick().await;

        for i in 0..num_tokens {
            let data = serde_json::json!({
                "id": format!("chatcmpl-{req_id}"),
                "object": "chat.completion.chunk",
                "choices": [{
                    "delta": {
                        "content": format!(" tok{i}"),
                    },
                    "index": 0,
                    "finish_reason": serde_json::Value::Null,
                }],
            });
            yield Ok(Event::default().data(data.to_string()));

            if i < num_tokens - 1 {
                interval.tick().await;
            }
        }

        let usage_data = serde_json::json!({
            "id": format!("chatcmpl-{req_id}"),
            "object": "chat.completion.chunk",
            "choices": [],
            "usage": {
                "completion_tokens": num_tokens,
                "prompt_tokens": prompt_tokens,
                "total_tokens": num_tokens + prompt_tokens,
            },
        });
        yield Ok(Event::default().data(usage_data.to_string()));

        yield Ok(Event::default().data("[DONE]"));
    };

    Sse::new(stream).keep_alive(KeepAlive::default())
}

/// POST /tokenize — trivial tokenizer (one token per whitespace-delimited word)
async fn tokenize(Json(payload): Json<TokenizeRequest>) -> impl IntoResponse {
    let prompt = payload.prompt.unwrap_or_default();
    // Simple tokenization: split by whitespace, assign incrementing IDs
    let num_tokens = if prompt.is_empty() {
        0
    } else {
        prompt.split_whitespace().count()
    };
    let tokens: Vec<u64> = (0..num_tokens as u64).collect();
    Json(serde_json::json!({
        "tokens": tokens,
        "count": num_tokens,
    }))
}

/// POST /detokenize — trivial detokenizer
async fn detokenize(Json(payload): Json<DetokenizeRequest>) -> impl IntoResponse {
    let tokens = payload.tokens.unwrap_or_default();
    // Produce a string with exactly tokens.len() "words"
    let prompt: String = (0..tokens.len())
        .map(|i| format!("w{i}"))
        .collect::<Vec<_>>()
        .join(" ");
    Json(serde_json::json!({
        "prompt": prompt,
    }))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn estimate_prompt_tokens(prompt: &Option<serde_json::Value>) -> usize {
    match prompt {
        Some(serde_json::Value::String(s)) => {
            if s.is_empty() {
                0
            } else {
                s.split_whitespace().count()
            }
        }
        _ => 32, // default
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    let state = Arc::new(AppState {
        token_interval: Duration::from_millis(cli.token_interval_ms),
        first_token_delay: Duration::from_millis(cli.first_token_delay_ms),
        default_num_tokens: cli.num_tokens,
    });

    let app = Router::new()
        .route("/v1/models", get(models))
        .route("/v1/completions", post(completions))
        .route("/v1/chat/completions", post(chat_completions))
        .route("/tokenize", post(tokenize))
        .route("/detokenize", post(detokenize))
        .with_state(state);

    let addr = format!("0.0.0.0:{}", cli.port);
    eprintln!(
        "Mock LLM server listening on {addr} \
         (token_interval={}ms, first_token_delay={}ms, default_tokens={})",
        cli.token_interval_ms, cli.first_token_delay_ms, cli.num_tokens
    );

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
