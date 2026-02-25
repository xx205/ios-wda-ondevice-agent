# Review Plan (parallel tracks)

## Scope
This repo contains:
- iOS Runner (WebDriverAgentRunner-Runner) overlay + patch workflow
- On-device Console app (SwiftUI)
- Scripts/tools for building, installing, and interacting with Runner

## Tracks (run in parallel)

1. **Security & Privacy**
   - Threat model for `/agent/*` endpoints (LAN/public exposure, auth, token handling)
   - API key storage / redaction / logs / export artifacts
   - TLS verification toggle scope and UX

2. **Correctness & Reliability**
   - Action execution semantics, retry behavior, edge cases (swipe/tap/type)
   - Responses vs Chat Completions modes, history restart logic, plan semantics
   - Error classification and recoverable failures

3. **UX & Product (Console + Runner Web UI)**
   - Information architecture, copy consistency, discoverability
   - Debuggability (chat/logs/raw, exports), defaults, validation

4. **Build/Install/DevEx**
   - Patch ↔ overlay synchronization workflow
   - iOS signing flow, scripts ergonomics, failure modes
   - Reproducible install for new machines

5. **Performance & Cost**
   - Polling frequency, payload sizes, screenshot scaling, token metrics
   - Caching behavior (Doubao seed session cache), memory growth

6. **Code Health & Maintainability**
   - File organization, duplication, naming, constants/config
   - Testability, modularity, error handling patterns

## Outputs
Each track writes one report:
- `security_privacy.md`
- `correctness_reliability.md`
- `ux_product.md`
- `build_devex.md`
- `performance_cost.md`
- `code_health.md`

Each report should include:
- Findings (bulleted, with file/symbol references)
- Severity (P0/P1/P2)
- Concrete recommendations (minimal diffs preferred)
- Suggested follow-up tasks

