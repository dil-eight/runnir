# Limits of a local run (B45)

Status: built (the rules and the workspace's limits in the Core, `PrepareLocalRun` with limits, the Limits row and panel in the review), drawn in `runnir.pen` (journey E, Row — Local run limits). Not tried with a real run against Docker Desktop or OrbStack.

## Problem

A local run gets fixed limits: 4 CPUs, 8 GB of memory and a 30-minute timeout, lowered to what the container engine has. The Run Locally review only shows them ("4 CPUs · 5.85 GB memory · 30 min timeout"). A build that needs more memory or time cannot get it, and a run that would take every CPU of the engine cannot be held back.

## Decisions

| Question | Decision |
| --- | --- |
| Where limits live | Per workspace: changed in the review, kept for the workspace's next local runs, with Reset to defaults |
| How they are changed | The Limits row keeps its text and gets **Change…**, which opens a panel of Runnir's own (not a system popover) |
| Who owns the rules | The Core: it caps what is asked at what the engine has, says what to warn about and keeps the workspace's limits |

## The review (S10)

- The Limits row: "4 CPUs · 5.85 GB memory · 30 min timeout", then **Change…**. Limits changed for the workspace add a "set for this workspace" tag.
- A line under the row says what is worth knowing without opening the panel: the engine is smaller than a default ("OrbStack has 5.85 GB, so memory is capped there. Give the engine more in its settings to raise it."), the limits are near the engine's capacity, or memory is low.
- The panel, above the row when there is no room under it:
  - CPUs: a stepper from 1 to the engine's CPUs, "of 8 on OrbStack".
  - Memory: a stepper in steps of 0.5 GB from 1 GB to the engine's memory, "of 5.85 GB".
  - Timeout: a stepper in steps of 5 minutes from 5 minutes to 6 hours (GitHub's limit for one job), "up to 6 h".
  - A stepper's + or − is disabled at its bound.
  - Warnings inside the panel, under the steppers.
  - "Changing a limit prepares the run again: confirm it again before it starts." Reset to defaults · Done.
- Done prepares the run again with the new limits: the plan, its blockers and its confirmation are new, and "I trust this workflow and repository" has to be ticked again.
- With the engine not answering, its CPUs and memory are unknown: Change… is disabled and the line says why.

## Warnings

The Core returns them with the plan, worded for the person:

- Every CPU of the engine: "the Mac and other containers slow down while the run goes on".
- Memory at 90% of the engine's or more: "the engine and other containers may run out of memory, and a job can be killed (exit 137)".
- Memory under 2 GB: "many builds do not fit and stop with exit 137".
- A default above what the engine has: the line under the row, with where to give the engine more.

Warnings never block a run.

## Core

- `PrepareLocalRunRequest` gets `limits` (CPUs, memory in bytes, timeout in seconds; unset keeps the workspace's) and `reset_limits`.
- `LocalRunPlan` gets the ceilings (`max_cpus`, `max_memory_bytes`, `max_timeout_seconds`), whether the limits are the workspace's own (`own_limits`), `limit_warnings` and `limit_note` (the line for a small or silent engine, not a warning).
- `localrun` caps what is asked at the engine's capacity and the bounds above, and words the warnings; one place for the rules.
- The workspace's limits are kept in its database on this Mac, as local data kept by Clear Cache; being a preference, they are not in the backup of local data (after a recovery the defaults come back). They are saved when a run with them is confirmed; a confirmed run with the defaults (after Reset to defaults) forgets them, so Reset changes nothing until a run is confirmed.
- The app never sends more than the plan allows; the Core checks it again.

## States drawn

1. Defaults, the engine smaller than the default memory.
2. The panel open, no warnings.
3. Overload: every CPU and nearly all memory, with the warnings.
4. Limits set for the workspace (low memory warning; the confirmation unticked after the change).
5. The engine not answering: Change… disabled.

## Tests

- Core: capping at the engine, the bounds, each warning, saving on confirm, Reset, a request above the ceiling.
- App: the panel's steppers at their bounds, Done preparing the run again and unticking the confirmation.
- Not covered by unit tests: a real run with changed limits against Docker Desktop or OrbStack.
