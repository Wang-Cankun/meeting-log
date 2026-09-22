# Prompt quality

Prompts separate evidence rules, classification rules, and an output contract. They avoid worked examples taken from particular meetings, which bias unrelated meetings; keep such cases in the evaluation set instead. Analysis first produces a draft, then a separate text request reviews decisions, task ownership, date precision, and uncertainties against the transcript and context. Both responses must decode before archiving. A failed review leaves the session recoverable. Global and selected project context reach both transcription and analysis. Project context is reference material: it supplies spelling, confirmed aliases, and output preferences; it does not establish spoken content, voice identity, or a meeting decision. See [context template](templates/project-context.md) when preparing a project.

Action items render as a table with distinct task, owner, deadline, and context/evidence columns. An empty field stays visibly unspecified. The optional uncertainties field renders a Needs verification section. Older summary responses still decode for reading; newly generated records can be saved with approximate or missing source references; these are marked for review rather than rejected. Pending transcript checkpoints remain compatible.

## Evaluation

Compare the previous and candidate prompts on the same audio excerpt and model. Preserve each exact prompt and response outside the repository when they contain internal meeting material. Compare summary extraction on a fixed transcript separately, so transcription changes do not conceal summary regressions.

Check each result against audio or confirmed source annotations:

- Every audible turn retained, in its spoken language, with uncertainty preserved.
- Transcript contains only turns; timestamps refer to the full recording and remain within the excerpt interval.
- Named speakers have conversational or user-confirmed support. Anonymous labels are not treated as identities across excerpts.
- Confirmed aliases are spelled consistently; unresolved terms remain unresolved.
- Each task has its own owner and task-specific deadline, or an empty field. Background, proposals, and unrelated responsibilities remain separate.
- Decisions reflect agreement or a settled directive; summaries preserve qualifications and unresolved questions.
- JSON decodes, and Markdown renders fields without merged columns or raw model commentary.

## Limits

The transcript remains model-generated text. Code validates turn formatting and monotonic timestamps within the excerpt bounds, and retries malformed output once before leaving a recoverable failure. This checks timestamp bounds, not alignment with the actual audio. Cross-excerpt speaker reconciliation and overlap removal are not enforced by code. Prompt improvements should not be described as guarantees for these properties. Recovered sessions may include blocks produced by older prompts. Existing archives are not automatically regenerated when context changes.

## Observed development results

A live comparison used the same five-minute problem excerpt with the old and revised transcription prompts. Subsequent revisions used the same full original transcript to isolate summary behavior. Internal audio, prompts containing project context, and provider responses stayed outside the repository.

- The initial revision improved turn formatting but still produced out-of-range timestamps. A subsequent run passed the format/bounds validator after one retry.
- Summary-only prompt revisions fixed a fabricated deadline year and separated unrelated onboarding tasks, but decision classification varied across runs.
- Adding a structured uncertainty list made unresolved terminology visible. A separate evidence-review request removed a methodological preference incorrectly labeled as a decision while retaining uncertainties and blank task deadlines.
- The final live response decoded into the app's model and rendered with separate action columns and a verification section.

These are development examples, not an independent accuracy benchmark. They establish the observed corrections, not complete word coverage, reliable voice identification, exact audio alignment, or generalization to unseen meetings. Existing archives remain untouched.
