## Performance & Cost Review

### Findings

- **P2: Polling churn (bandwidth + battery).**  
  Live tooling tends to poll `/agent/status`, `/agent/logs`, `/agent/chat` frequently and fetch full blobs each time. This can cause unnecessary network and CPU churn, especially on mobile.

- **P2: Screenshot payload bloat.**  
  Each step embeds base64 screenshots into model requests; long runs accumulate large payloads and stored screenshot history for export.

- **P2: Export can re-download “everything” + every screenshot.**  
  HTML export flows can result in many requests (one per step screenshot), making export heavy for 100-step runs.

- **P2: Caching visibility.**  
  Token metrics exist and Doubao caching can be enabled, but the UX/telemetry could better indicate whether caching is actually being applied (cached tokens > 0).

### Recommendations

1. Prefer delta / event-driven updates (SSE/long-poll) or reduce polling frequency; poll only when running or when a version counter changes.
2. Add stronger payload controls: keep fewer screenshots by default, consider JPEG/quality knobs or cropping, and cap stored screenshot steps.
3. Make exports bounded by default (e.g., last N screenshots) and batch screenshot fetches.
4. Improve telemetry: surface whether cache is enabled and whether cached tokens are actually observed.

