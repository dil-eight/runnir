# Global search and the notification bell (B43, B44)

Status: built, with the gaps listed under "Not built". The bell (B44): the list, the badge, the read rules and the reconcile; they have not been tried against real macOS notifications. The global search (B43): the field, the layer (S20), `SearchWorkspaces` in the Core, the settings list. The bell's list is drawn in journey F of the canvas (Row — Notification bell: unread, all read, nothing yet, and when an entry counts as read).

## The top strip

The strip above the two islands (menu, content) holds, left to right: the window controls and the project switcher; a global search field in the middle; the notification bell on the right. There is no branch switcher: the branch is read from Git and only shown where it matters (the Overview toolbar, the runs list), because Runnir never checks out a branch.

## Global search (B43)

- A field in the middle of the strip, opened with a shortcut (proposal: ⌘K) or a click. Results open in a layer over the window.
- It searches everything the window can show: workflows and their jobs, runs (the same Core search as the runs list, so B33 and B40 results appear here), pull requests, workflow files and their contents, local runs, and **settings** (each setting, section and toggle by its name and description; choosing one opens Settings at that item).
- Results are grouped by kind, with the kind's icon and its place ("Runs · mobile-app"). Return opens the first result, arrow keys move, Escape closes.
- Scope: **all registered workspaces**, with the window's own workspace first. Results are grouped by kind and name their workspace ("Runs · mobile-app"); a scope control in the field narrows the search to this workspace. Settings belong to no workspace.
- It stays cheap because it only reads what is already saved on this Mac. The Core goes through the workspaces by id, as `Usage` and `ClearCache` already do: an open workspace answers from its live store, a closed one is read through `store.Peek` (the database opened read-only from disk, no lock, no migration). Nothing runs `git` and nothing goes to GitHub. Each database holds at most 5,000 runs, so a query is a few milliseconds per workspace and the databases are read in parallel.
- What a closed workspace can give: its saved runs, pull requests, workflows (by name and path), local runs and dispatch history. Workflow file *contents* need access to the folder, so they come only from a workspace whose folder grant is valid; one with a stale or revoked grant, or a folder that moved, shows its names only, and the group says so.
- Results from a closed workspace carry how old the data is ("saved 3 days ago"). Choosing one opens that workspace's window (or focuses it) and goes to the result.
- Queries use the run search grammar where it applies (`branch:`, `author:`, `status:` and the rest of B40); other kinds match on words.
- Settings are searched offline from a static list built in the app. Everything else comes from the Core's saved data; nothing goes to GitHub from the global search except through the deep run search of B40, started by the user.

## The notification bell (B44)

- The bell shows how many notifications are unread (a badge with the number; none when zero). A click opens a list over the window: newest first, each with a kind icon, title, body, time and an unread dot; **Mark all as read**; a link to Settings › Notifications.
- It lists what Runnir sends as system notifications (S19): pull request checks and local runs. Kinds turned off in Settings are not sent and so are not listed.
- Choosing an entry does what clicking the system notification does (opens the pull request on GitHub, or shows the workspace of a local run) and marks it read.
- A system notification of failed pull request checks also has an Open Run button (S19): it opens the failed run, as a click on the notification does, and reads the entry. The list matches the canvas: the bell is pressed while the list is open, the entry under the pointer is highlighted, passed and failed show as outlined icons.

### When a notification counts as read

A notification is read, in the bell and in the badge, as soon as any of these happens:

1. The user opened it from the bell.
2. The user came from the system notification: a click on the banner or on the entry in Notification Center, which opens its target (`UNNotificationDefaultActionIdentifier`).
3. The user closed it in the system: dismissed the banner, cleared the entry in Notification Center, or cleared all. A notification closed in the system counts as read here too.

How the app learns of 2 and 3:

- Notifications are posted in a category with `.customDismissAction`, so macOS calls the delegate with `UNNotificationDismissActionIdentifier` when one is dismissed while Runnir is running.
- A dismissal while Runnir is not running (or a "Clear All") is not reported. On launch and whenever the app becomes active, the unread list is compared with `getDeliveredNotifications()`: an unread entry that macOS no longer holds is marked read.
- If the system showed nothing (permission refused, Focus mode that holds it back), the entry stays unread until it is opened in the bell. Entries Focus only delays are still delivered later and follow the same rules.

Reading in one window is read in all windows: the list is app-wide, not per workspace.

## Storage

The list is kept on this Mac, app-wide, and survives a restart; the latest 100 entries or 30 days, whichever is fewer. It is device-private like the other local data and goes through no server.

## Built, and not built

- Built: the field in the strip (⌘K), the layer with the scope control, kind tabs with counts and results grouped by kind (runs, pull requests, workflows by name and path, local runs, settings), the window's workspace first, "saved N days ago" for a closed workspace, a note for a workspace that could not be read, a row "Show all N runs" and a footer link that open the Runs list with the query typed in (the deep search on GitHub starts there, from its button).
- Where a result leads: a run → the Runs list with it selected (a run the saved list does not hold is found by searching its number); a workflow → the Overview with it selected; a local run → the Workspace section's local run; a pull request → GitHub in the browser, as the window has no pull request screen; a setting → Settings at its section.
- Not built: workflow file *contents* and jobs (they need the folder grant and a scan of the files, which the Core does not do for a closed workspace); opening a setting at its item (the list knows the section only); opening one particular local run (the history is not shown anywhere in the app yet).

## Not decided

- The shortcut for the search (⌘K is a proposal; it clashes with "clear" in some terminals).
- Whether it opens files in the editor or only the workflow files. A deep run search on GitHub stays per repository and is started by the user, never across all workspaces at once (it would spend the same rate limit).
- Whether the bell lists failures only or successes as well when Settings › Notifications says "Failures only" (proposal: follow that setting).

## Tests

- App: a notification becomes read on bell open, on a system click and on a system dismissal; reconcile on launch marks entries macOS no longer holds; read in one window shows in another; the badge counts only unread.
- Search: settings are found by name and by description and open at the right item; run results match the runs list for the same query.
- Core: a query over an open and a closed workspace returns both, the closed one without taking its lock; a workspace with a damaged or missing database is skipped with a note instead of failing the search; file contents are left out for a workspace without access.
