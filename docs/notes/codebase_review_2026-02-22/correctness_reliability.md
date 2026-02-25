## Correctness & Reliability Review

### Findings

- **P1: Chat Completions mode context grows unbounded.**  
  Each step appends a full user message (task/plan/notes/screen info) + assistant action into `self.context`, and future model calls reuse the entire array. Long runs will exceed context windows and fail/truncate.  
  Recommendation: keep a sliding window (last N rounds) and build messages from that, not the full history.

- **P1: Plan merge can treat rephrases as new items and inflate `done_count`.**  
  If the model rewords a plan item text, monotonic merge can keep both the old and new item, potentially increasing completed count spuriously. This can incorrectly trigger Responses-chain restarts.  
  Recommendation: normalize plan item keys (whitespace/punctuation/case) or introduce stable IDs for plan items.

### Recommendations

1. Bound chat history for Chat Completions mode (sliding window).
2. Stabilize plan identity to avoid “rephrase = new item” bugs.
3. Add regression tests for plan merge and restart scheduling (synthetic plan sequences).

