# agentevals-go — roadmap additions from running it against kagent

The evals repo has no roadmap file; `docs/STATUS.md`'s "Not yet ported" section
plays that role, and it is written from the Python port's side: what upstream
has that Go does not. This list is written from the other side — a real
producer (kagent 0.10.1, Go ADK runtime, Gemini) pointed at it in abox — and
every item in section A comes from something that broke in LAB8, with the
evidence in [README.md](./README.md) and `results/`.

Each item: the problem, what shows it, the proposal, and how to know it is
done. Sections B–D are the three directions the lab named (continuous
evaluation, skills, external evals); they depend on A, and section E says in
what order.

## A. Before anything continuous: what stops kagent traces being scored

Every one of these was worked around by hand in LAB8. A continuous pipeline has
no hands.

**A1. Group sessions by trace, not only by `gen_ai.conversation.id`.**
kagent's controller-side spans (`POST /api/a2a/...`, a bare `invoke_agent`)
carry no conversation id; the agent-side spans do. One A2A request becomes two
sessions, and the agent-side one never completes because its root's parent is
in the other — so live invocation extraction never runs.
*Proposal:* when any span of a trace carries a conversation id, assign every
span of that trace to that session; fall back to the synthetic name only for
traces that have none.
*Done when:* one `ask.sh` call produces one session that reaches
`isComplete=true` with invocations, and `collect-trace.sh` is no longer needed.

**A2. Don't count a transport span as an invocation.**
kagent emits `invoke_agent` in the controller and again in the agent; each
becomes an invocation, and a one-question eval set fails with "actual and
expected invocation lists differ in length (2 vs 1)".
*Proposal:* an `invoke_agent` with no ADK LLM descendants of its own, whose only
child is another `invoke_agent`, is a hop, not a turn — collapse it into the
inner one.
*Done when:* the unfiltered helm-agent trace scores `tool_trajectory_avg_score
= 1.0` against `evalsets/helm_releases.json`.

**A3. Say why a trace has no invocations.**
With kagent's Gemini provider, `generate_content` spans carry tokens and no
`gcp.vertex.agent.llm_request`/`llm_response`, and the result is `No
invocations extracted from trace` — the same message as for a malformed trace.
The cause is in kagent (only its OpenAI/Anthropic/Bedrock/Ollama adapters call
the telemetry helper), but agentevals is where it surfaces.
*Proposal:* a conversion warning that names it — "N generate_content spans, 0
with request/response content; the producer is not recording message content"
— and a fallback to `gen_ai.input.messages`/`gen_ai.output.messages` where a
producer uses semconv instead. Separately, an issue on kagent for the Gemini
adapter.
*Done when:* a Gemini-provider trace produces a warning that points at content
capture, not a bare "no invocations".

**A4. A default judge that exists.**
The default judge is `gemini-2.5-flash` (ADK's `JudgeModelOptions`). For a new
Gemini key it returns 404 "no longer available to new users", while
`models.list` still lists it. An evaluator config that names no model fails
out of the box.
*Proposal:* `AGENTEVALS_JUDGE_MODEL` for the server-wide default, and a
startup probe that makes one cheap call and logs the result, so a dead judge is
found at deploy time, not at the first evaluation.
*Done when:* `serve` with a new key and no `judgeModel` either works or says
at startup which model it cannot reach.

**A5. Separate "the judge was unavailable" from "the answer failed".**
Five samples per invocation, and one 503 "high demand" fails the metric. On
2026-09-24 every flash model from 3.5 to 3.8 passed or 503'd depending on the
minute. `evaluate-all.sh` retries whole cases; that belongs in the judge client.
*Proposal:* per-sample retry with backoff on 429/503; if samples are still
missing, status `JUDGE_UNAVAILABLE` rather than `ERROR`, with the number of
samples that did come back.
*Done when:* a 503 burst shows up as a distinct status in `summary.tsv`, and
never as a FAILED score.

**A6. Say which rubric failed.**
Both rubric metrics return `details: null`. *k8s_failed_helmrelease* scored 0.5
on two rubrics — inferable; with five it would not be. `hallucinations_v1`
already returns per-sentence reasoning, so the shape exists.
*Proposal:* `details.per_invocation[i].rubrics[]` with id, verdict (after the
majority vote), and one rationale.
*Done when:* the summary for that case names the xray-memory root-cause rubric
as the failing one.

**A7. Make the threshold visible, and stricter for rubrics.**
The default threshold is 0.5 with `>=`, so a response that met one of two
required rubrics was reported PASSED.
*Proposal:* report the threshold in every `MetricResult`; for rubric metrics,
either default to 1.0 or require an explicit threshold — a rubric set is a list
of requirements more often than a vote.
*Done when:* a result can't be read as PASSED without also reading what it had
to pass.

**A9. Ground hallucination checks in tool results, as an option.**
`hallucinations_v1` builds its context from instructions, the user prompt and
tool definitions only, matching ADK Python. On *k8s_failed_helmrelease* that
marked 23 of 24 sentences `unsupported` — including ones copied verbatim from a
tool response — and scored 0.04; it could not pick out the one sentence that
really was weak.
*Proposal:* an evaluator option (`include_tool_responses: true`) that adds the
invocation's tool results to the validator's context, off by default for
fidelity with upstream, and the UI description saying which mode was used.
*Done when:* the same trace scores the copied sentences `supported` and leaves
the timeout-as-root-cause sentence as the one in question.

**A8. Let `run` read what `serve` writes.**
`agentevals run` only loads Jaeger JSON; `/api/streaming/get-trace` returns
OTLP JSONL. The auto-detecting loader exists (`internal/loader`) and is only
wired to `/api/evaluate`.
*Proposal:* use it in the CLI.
*Done when:* `agentevals run traces/helm_releases.jsonl ...` works, and LAB8's
`evaluate.sh` can drop its port-forward.

## B. Continuous evaluation

The pieces exist separately: OTLP ingestion, session persistence, eval sets
built from sessions (`create-eval-set`), saved eval sets, run history, and MCP
tools to read it back. What is missing is the loop that connects them without a
person.

**B1. Score sessions as they complete.**
`POST /api/streaming/evaluate-sessions` is not ported (STATUS.md). Port it,
then run it from session completion: every completed session gets the
reference-free metrics (rubrics, hallucinations) configured for its agent; a
session whose first user turn matches a saved eval case also gets the
reference metrics (trajectory, response match) for that case. Depends on A1–A3.

**B2. Budget the judge.**
One rubric metric is five judge calls per invocation; LAB8's staleness case
was one question and 20 spans. Scoring all traffic is a cost decision:
per-agent sampling rate, a daily judge-call cap, and reference metrics
(no judge) always on.

**B3. Scores as time series, not only as runs.**
Export `agentevals_score{agent, metric, eval_case}` and the pass rate as OTel
metrics to the collector abox already runs, so Grafana shows a regression and
can alert on it. The interesting alert is not "a score is low" but "a score
moved when a ModelConfig or an Agent's prompt changed" — the same shape as the
re-evaluation triggers in this repository's ADRs, made automatic.

**B4. A pre-merge gate is a different thing — say so.**
agentevals scores recorded traffic and never re-executes. A gate on a PR that
changes an agent needs that agent running somewhere and questions put to it:
LAB8's `run-cases.sh` → `evaluate-all.sh` in an ephemeral KinD cluster. It
belongs in CI next to agentevals, not inside it, and the roadmap should not
promise it as a feature.

**B5. MCP for the agent that investigates.**
`list_runs` and `get_run_results` let a client read history. Add
`evaluate_session` (score one session now) and `compare_runs` (per-metric
deltas between two runs or two time windows), so an agent — triage, in this
cluster — can answer "did helm-agent get worse after the model change?" from
data. Needs A6: without per-rubric details the answer is a number with no
reason.

**B6. Continuous evaluation means continuous content capture — gate it.**
Scoring needs prompts and responses in spans (A3); that is exactly what LAB6
found no reference deployment redacts, and LAB5 showed an agent will hand over
a credential it can see. The OTLP receivers are never authenticated in this
port; Phoenix was the only one of three backends in LAB7 that authenticated
ingest. Before B1 runs on real traffic: an auth option on the receivers, a
retention setting for stored sessions, and a redaction step (by attribute key,
as LAB5's ingest does) before a span is written.

## C. Skills

Two readings, both worth having.

**C1. Evaluate skill selection.** An agent that loads skills makes a choice
before it makes a tool call, and a wrong skill produces a plausible answer by
the wrong route — the same "right answer, wrong mechanism" that LAB5 named for
ranking vs set selection. If the producer records the loaded skill on the span
(a `gen_ai.agent.skill`-style attribute; not in semconv today), a
`skill_selection` metric is a trajectory metric over one step: expected skill
vs actual, EXACT or ANY_ORDER. Eval sets gain an `expected_skills` field next
to `tool_uses`.

**C2. Evaluation as a skill.** Package "write an eval case from this session,
save it, score it" as a skill over the MCP tools of B5, so the person who just
saw a bad answer turns it into a regression case in the same conversation. The
eval set that LAB8 wrote by hand is what such a skill would produce; the hand
step that must stay is the one LAB8 kept — checking the expected answer against
the system before saving it.

## D. External evals

**D1. The custom evaluator protocol (stdin/stdout JSON), not yet ported.**
It is what turns domain checks into metrics. LAB8's most useful check was done
by hand: whether *k8s_failed_helmrelease*'s claimed cause matched the pod's
actual events. An evaluator that receives the agent's answer and queries the
cluster read-only to verify its claims is a ground-truth metric no judge model
can offer — and the same protocol lets such checks live in the agent's repo
rather than in agentevals.

**D2. Phoenix as a destination, not a competitor.**
LAB7 concluded Phoenix is the right home for LLM telemetry in abox. Scores
written back as Phoenix span annotations (or evaluations) on the trace they
judged put the number next to the conversation, instead of in a second UI. The
fan-out collector from LAB7 already delivers one agent's spans to several
backends at once; adding agentevals as a fourth leg is a config change.

**D3. `openai_eval` and Vertex backends** — ported or not, they are someone
else's judge with someone else's availability (A5) and credentials. Worth it
where a team already pays for them; not a priority here.

## E. Order

1. **A1, A2, A3** — without them kagent traffic cannot be scored without a
   person in the loop, so nothing continuous can start.
2. **A4–A7, A9** — without them a score cannot be trusted: a judge that 404s
   by default, 503s read as failures, half-met requirements read as passes,
   failures with no reason, and a hallucination score that fails every fact a
   tool supplied.
3. **B6 before B1** — capture and store conversation content only once it is
   authenticated, retained deliberately and redacted.
4. **B1, B3**, then **B2** as soon as B1 shows its real cost.
5. **B5, D1** — the investigation loop and ground-truth checks.
6. **C, D2** — once the producers record what C needs, and once abox decides
   (ADR-0005, still unwritten) that Phoenix owns LLM telemetry.

A8 can go in at any point; it is small and it removes a workaround.
