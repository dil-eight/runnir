# Global search and the notification bell (B43, B44)

Status: design agreed, drawn on one screen only (S03 Overview, "Islands layout, proposal"), not implemented.

## The top strip

The strip above the two islands (menu, content) holds, left to right: the window controls and the project switcher; a global search field in the middle; the notification bell on the right. There is no branch switcher: the branch is read from Git and only shown where it matters (the Overview toolbar, the runs list), because Runnir never checks out a branch.

## Global search (B43)

- A field in the middle of the strip, opened with a shortcut (proposal: ⌘K) or a click. Results open in a layer over the window.
- It searches everything the window can show: workflows and their jobs, runs (the same Core search as the runs list, so B33 and B40 results appear here), pull requests, workflow files and their contents, local runs, and **settings** (each setting, section and toggle by its name and description; choosing one opens Settings at that item).
- Results are grouped by kind, with the kind's icon and its place ("Runs · mobile-app"). Return opens the first result, arrow keys move, Escape closes.
- Scope is the repository of the window. Searching all registered workspaces is not decided.
- Queries use the run search grammar where it applies (`branch:`, `author:`, `status:` and the rest of B40); other kinds match on words.
- Settings are searched offline from a static list built in the app. Everything else comes from the Core's saved data; nothing goes to GitHub from the global search except through the deep run search of B40, started by the user.

## The notification bell (B44)

- The bell shows how many notifications are unread (a badge with the number; none when zero). A click opens a list over the window: newest first, each with a kind icon, title, body, time and an unread dot; **Mark all as read**; a link to Settings › Notifications.
- It lists what Runnir sends as system notifications (S19): pull request checks and local runs. Kinds turned off in Settings are not sent and so are not listed.
- Choosing an entry does what clicking the system notification does (opens the pull request on GitHub, or shows the workspace of a local run) and marks it read.

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

## Not decided

- The shortcut for the search (⌘K is a proposal; it clashes with "clear" in some terminals).
- Whether the search covers all registered workspaces, and whether it opens files in the editor or only the workflow files.
- Whether the bell lists failures only or successes as well when Settings › Notifications says "Failures only" (proposal: follow that setting).

## Tests

- App: a notification becomes read on bell open, on a system click and on a system dismissal; reconcile on launch marks entries macOS no longer holds; read in one window shows in another; the badge counts only unread.
- Search: settings are found by name and by description and open at the right item; run results match the runs list for the same query.
