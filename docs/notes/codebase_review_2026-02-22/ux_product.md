## UX & Product Review (Console + Runner Web UI)

### Findings

- **P1: Runner Web UI validation is weaker than Console.**  
  The console has detailed `runValidationErrors` logic, but the Runner web UI can still attempt Start with missing Base URL/model/task/API key/token and only show opaque HTTP errors. This is avoidable by mirroring the console’s preflight checks and disabling Start until satisfied.

- **P2: Runner Web UI chat/log rendering is “raw dump” only.**  
  Console’s step cards (screenshot + reasoning + action + raw details) are much more debuggable than the web page’s `<pre>` output. The web view could at least group by step and support structured blocks.

- **P2: Disabled actions lack inline explanation.**  
  Some buttons (e.g., config export) become disabled without surfacing the precise validation failures next to the controls.

- **P2: “Quick Start” state requires drilling into “Details.”**  
  Readiness is mostly implied by disabled Start; key failure reasons are hidden behind disclosures, increasing user confusion.

### Recommendations

1. **Unify validation**: reuse the same required-field rules for Console + Web UI and present inline error bullets.
2. **Improve web chat rendering**: step grouping, collapsible raw JSON, and optional screenshots to approach Console-level debuggability.
3. **Add persistent status chips** under Start/Stop: Runner reachable, config ok, token ok, etc.
4. **Tighten copy** around “what is preventing a run” so users don’t interpret local Runner issues as remote server failures.

