## Code Health & Maintainability Review

### Findings

- **P1: `ConsoleStore` is doing too much.**  
  `apps/OnDeviceAgentConsole/OnDeviceAgentConsole/ConsoleStore.swift` is a very large class that owns config defaults, QR import/export, event stream parsing, network/probing logic, start/stop/reset flows, validation, and UI-facing state. This makes it hard to reason about, test, and change safely.

- **P2: Parsing helpers duplicated.**  
  Numeric/string/boolean JSON helpers are effectively implemented multiple times inside `ConsoleStore` for QR validation vs import; this creates drift risk.

- **P2: Validation strings are inconsistently localized.**  
  Some user-visible validation/errors are hard-coded English while other UI uses `NSLocalizedString`, which tends to regress over time.

- **P2: No automated tests for critical logic.**  
  QR parsing/validation, SSE decode, and AgentClient request/response handling have no unit tests; these are high churn areas.

### Recommendations

1. **Refactor `ConsoleStore` into smaller services** (EventStream manager, Config validator, AgentClient wrapper) and keep `ConsoleStore` as a thin view-model.
2. **Deduplicate parsing/validation logic** into shared helpers, and unit-test them.
3. **Centralize + localize validation/errors** so messages remain consistent across views and languages.
4. **Add a test target** for parsers/validators and mocked agent endpoints.

