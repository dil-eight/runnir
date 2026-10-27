# Run graph in the run inspector (B41)

Status: built (Core `GetRunWorkflow`, the graph, the log layer over the list and the graph); not yet tried against a real run. States drawn in Pen (S08, Row — Run inspector).

## Change

The run inspector no longer opens on a jobs list with a log beside it. It opens on the run's graph, drawn as on the Overview (C26 job nodes in columns, joined by arrows), with a status and a time on every node. A job's log is read in a layer over the graph.

## Behaviour

- The runs list keeps its place and width (about 28% of the window, 300 pt). The inspector takes the rest, and the graph is its default body: no log is loaded until a job is selected. A failed run shows a failure line below the graph ("Failed in build-ios › Archive", the first error line) with "Open the log"; an active run shows where it is and "Follow the log".
- Selecting a job opens the layer: a sheet over the dimmed runs list and graph, with the jobs and the steps of the selected job on the left and the log on the right, the log's search, follow and wrap controls in its header, and Expand and Close. Jobs can be switched inside the layer.
- Expand makes the layer fill the whole content area, the runs list and the toolbar included; the same control restores it. Close returns to the graph. Escape closes.
- Inspect failure opens the layer on the failed step.
- An active run updates the graph and, when the layer is open, follows the log.
- Logs that expired show their message inside the layer; the graph is still there.

## Data

The API gives a run's jobs without their order. The Core reads the workflow file at the run's `head_sha` (one request, as the dispatch form does), builds the graph from `needs`, and matches nodes to jobs by name: matrix jobs become one node `name ×N` that opens on its first failed job, jobs of reusable workflows match by their `caller / job` prefix. When the file cannot be read, has no `needs`, or a node cannot be matched, the inspector shows the plain list of jobs, in the order GitHub gives, with a note that they are listed without their order. A run is never hidden because its graph could not be drawn.

## Not decided

- Whether the expanded layer remembers its size per window.
- Edges for `needs` across workflow files (workflow_run chains): the Overview draws them, the inspector does not for now.

## Delivery

One pull request after B40's first one: the Core graph endpoint and matching, then the inspector. The old jobs-and-log body goes away.
