## Security & Privacy Review

### Findings

- **P1: Token can be exposed via query/cookie/localStorage paths.**  
  The web UI accepts an Agent Token via querystring/cookie and persists it in storage for JS fetches. Since Runner is HTTP on port 8100, tokens in URLs/cookies are plaintext-on-the-wire and easier to leak (sniffing, logs, referrers, in-origin script access).

- **P2: `insecure_skip_tls_verify` is persistent and easy to leave enabled.**  
  When enabled, the model-service client accepts any certificate for the host, potentially exposing API keys to MITM on untrusted networks if the user forgets it’s on.

- **P3: Redaction is “field-name based,” so future secrets can slip.**  
  Current masking for API key/authorization is good, but relies on explicit field names; new secret fields could be logged/exported unless redaction is kept up to date.

### Recommendations

1. Reduce token exposure:
   - Avoid querystring token after initial pairing.
   - Avoid long-lived localStorage/cookie tokens where possible.
   - Consider short-lived tokens and “rotate token” UX.
2. Make TLS-skip safer:
   - Treat as session-only, or require explicit re-enable; show prominent warnings.
3. Add “no secret in raw outputs” regression checks:
   - Unit tests that scan raw JSON/log exports for patterns (api keys, bearer tokens).

