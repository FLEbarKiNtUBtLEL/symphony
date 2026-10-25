# Logging Best Practices

This guide defines logging conventions for Symphony so Codex can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging Codex execution lifecycle events, include:

- `session_id`: combined Codex thread/turn identifier.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it.
- `Codex.AppServer`: log session start/completion/error with issue context and `session_id`.

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a Codex session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?


## Run stop causes

Self-withdrawal reconciliation uses the routing observation's recorded detail;
provider-capacity observations use `cause=usage_limit` and preserve the matching
phrase in the run log, including when a run raises, throws, or exits. These
capacity observations are advisory and do not change turn control flow.

An automatic approval-answer construction failure remains
`approval_auto_answer_unavailable` as the final event and blocker explanation,
rather than being replaced by a generic operator-input event.

The orchestrator owns the live cause's lifetime: it clears causes after stopping
workers, when releasing claims, and before scheduling another attempt. A new
dispatch also clears stale observations left by an orchestrator-only restart. Blocked
claims keep their cause until reconciliation releases them. Run-log writes read
but do not consume that observation so blocked reconciliation can still name it.
