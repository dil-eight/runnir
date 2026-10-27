# Status filter on the runs list (B42)

Status: built. The Core assigns each run its status (`WorkflowRun.status_group`, from `runsearch.StatusOf`); the app shows the chips and the menu and counts the runs it holds by that status. States drawn in Pen (S07 Runs list: menu open, filters applied).

## Behaviour

- Beside the search field of the runs list there is a filter icon button. A click opens a menu of checkboxes: Success, Failed, Cancelled, In progress, Queued, Skipped.
- Each ticked status shows as a chip under the field. Every chip has its own remove control. A **Clear all** link ends the chips row and is repeated in the menu footer.
- While at least one chip is applied the filter button carries an indicator (a dot and an accent border), so the filter is visible with the menu closed.
- Clear all removes the chips only. The typed query stays and has its own clear control in the field.

## How it combines

- Ticked statuses combine with OR: a run matches when its status is any of them.
- The status filter combines with AND with the typed query and with the branch filter. The list shows the runs that match all of them, and its summary line says so ("1 of 812 saved runs match “release” and the filters").
- The typed query affects the menu too. The count beside each status is the number of saved runs with that status that match the typed query and the branch filter, whatever is ticked, so it shows what ticking the status would give. The menu header says "matching “query”" while a query is typed. A status with no match is dimmed but stays selectable; a ticked status that drops to zero keeps its chip.
- Statuses apply to the saved runs offline. They are not a request to GitHub.

## Where it lives

- The Core owns the definition of a run's status (which of GitHub's `status` and `conclusion` values count as which of the six): every run it sends carries `status_group`, and the same mapping serves `status:` in a search. The app does not read status and conclusion for the filter; it counts the runs it holds by the status the Core gave, and a run without one matches no ticked status.
- Chips and the filter are kept per window while the app runs, not across launches.

## Decided since

- `action_required` falls under Queued (it waits for a person), `neutral` and `stale` under Skipped.

## Not decided

- B40's deep search on GitHub takes one `status` value per request: with several chips it makes one request per status, or reads unfiltered pages and filters here.

## Tests

- Core: the status mapping for every `status` and `conclusion` pair; counts follow the query and the branch filter; OR between statuses, AND with the query.
- App: chips, the indicator, Clear all keeping the query, a ticked status that drops to zero keeping its chip.
