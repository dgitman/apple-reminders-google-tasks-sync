# remtasks

Two-way sync between **Apple Reminders** and **Google Tasks**, with support for **multiple Google accounts**. Runs locally on your Mac, no cloud middleman, no subscription.

Map each Reminders list (or a whole Reminders group) to a Google account, and remtasks keeps matching Google Tasks lists in sync in both directions.

```
Apple Reminders (iCloud)                       Google Tasks
  Personal/  Finances, Home, Travel ...  <-->   you@gmail.com        Finances, Home, Travel ...
  Business/  Clients, Deals ...          <-->   you@yourcompany.com  Clients, Deals ...
  Reminders (default list)              <-->   you@gmail.com        My List
```

## Features

- **Two-way sync** of title, notes, due date, and completion for every mapped list.
- **Multiple Google accounts.** Map lists individually or by Reminders group.
- **Same list names on both sides.** Google lists are created and renamed to match Apple's. A per-list override lets you pick a different Google name (for example the default `Reminders` list to Google's `My List`).
- **Conflict resolution:** the most recently modified version wins, decided per task on the fields both platforms can hold.
- **Completion sync** in both directions.
- **Deletion sync** in both directions, with a safety cap and a dry-run mode. An edit made after a deletion on the other side re-creates the task rather than losing the edit.
- **List deletion** in both directions (opt-in via `safety.deleteLists`).
- **Subtasks.** Apple subtasks become Google subtasks, and re-nesting in Apple is mirrored to Google. Google subtasks arrive in Apple as regular reminders (see limitations).
- **Due times and alarms are preserved.** Google only stores a day; remtasks keeps your Apple time-of-day and alarms when Google changes the date, and gives Google-created tasks a default time and alarm you choose.
- **Recurring reminders.** Apple owns the recurrence rule. Google sees the current occurrence; completing it in Google completes it in Apple, Apple advances to the next occurrence, and that becomes a new Google task while the finished one stays completed as history.
- **Safe by design:** local SQLite state bound to your specific iCloud and Google identities, a first run that only links and creates, a cap on deletions per run, a lock against concurrent runs, and `--dry-run`.

## Limitations (Google Tasks API)

| Apple Reminders | Google Tasks | remtasks behaviour |
|---|---|---|
| Due date with time | Date only | Apple keeps the time; Google gets the day. Google date changes keep Apple's time. |
| Alarms, early reminders, location alerts | None | Apple-only, never touched. Alarms pinned to the due time move with it. |
| Priority, flags, tags, URL, attachments, images | None | Apple-only, never touched. |
| Recurrence rules | None via API | Apple-only. Google sees one occurrence at a time. |
| Subtasks | Subtasks | Apple to Google: full. Google to Apple: flat (no public API to nest reminders). |
| Grocery-list sections | None | Flat on the Google side. |
| Groups (folders) | None | Used only for account mapping. |

Google Tasks titles are capped at 1024 characters and notes at 8192; longer values are truncated on the Google side only.

## Requirements

- macOS 14 or later, signed in to iCloud with Reminders enabled.
- Swift 6 toolchain (Xcode or Command Line Tools).
- Your own Google Cloud OAuth client (free, five minutes, instructions below).

## Install

```bash
git clone https://github.com/dgitman/apple-reminders-google-tasks-sync.git
cd apple-reminders-google-tasks-sync
scripts/make-signing-identity.sh   # one time: stable code-signing certificate (see Full Disk Access below)
scripts/install.sh
```

This builds a release binary, installs it as `~/Library/Application Support/remtasks/Apple Reminders & Google Tasks Sync` with `~/.local/bin/remtasks` symlinked to it (macOS shows a bare executable's file name in Full Disk Access and Background Items, so the real file carries the readable name), ad-hoc signs it, and creates `~/.config/remtasks/config.json` from the example if none exists.

## Google Cloud setup

Every user supplies their own OAuth client so that nobody's tokens flow through a shared app.

1. Open [console.cloud.google.com](https://console.cloud.google.com/) and create a project (any name, for example `remtasks`).
2. **APIs & Services > Library**: enable **Google Tasks API**.
3. **APIs & Services > OAuth consent screen**: choose **External**, fill in the app name and your email. Under **Test users**, add **every Google account you will sync**. (Keeping the app in "Testing" is fine for personal use.)
4. **APIs & Services > Credentials > Create credentials > OAuth client ID**: application type **Desktop app**.
5. Download the JSON and save it as `~/.config/remtasks/google-client.json`.

One client works for all your accounts.

## Configure

Edit `~/.config/remtasks/config.json`:

```json
{
  "accounts": {
    "personal": { "email": "you@gmail.com" },
    "work": { "email": "you@yourcompany.com" }
  },
  "groups": {
    "Personal": "personal",
    "Business": "work"
  },
  "lists": {
    "Reminders": { "account": "personal", "googleListName": "My List" },
    "Shared Groceries": { "account": "personal" },
    "Someday": { "skip": true }
  },
  "remindersSource": "iCloud",
  "newTaskDefaults": { "dueTime": "09:00", "alarm": true },
  "safety": { "maxDeletesPerRun": 20, "deleteLists": false },
  "completedHistoryDays": 30,
  "google": {
    "clientSecretFile": "~/.config/remtasks/google-client.json",
    "tokenStorage": "file"
  }
}
```

- `accounts`: a key of your choosing per Google account, with the email that must sign in. Sign-in is refused if a different account is picked in the browser.
- `groups`: Reminders group (folder) name to account key. Every list inside that group syncs there. New lists added to the group are picked up automatically.
- `lists`: per-list rules, which take precedence over groups. `account` picks the account, `googleListName` overrides the Google list name, `skip: true` excludes the list.
- Lists that are neither in a mapped group nor listed explicitly are ignored.
- Google's built-in default list is usually titled "My Tasks". To pair it with an Apple list, set that list's `googleListName` to the exact existing title; otherwise a new Google list is created.
- `newTaskDefaults`: time of day and alarm given to reminders created from Google tasks that carry a due date. Set `dueTime` to `null` for all-day.
- `safety.maxDeletesPerRun`: more deletions than this in one run are skipped unless you pass `--allow-deletes`.
- `safety.deleteLists`: propagate list deletions. Off by default.
- `completedHistoryDays`: completed items older than this are left alone on both sides. They are not copied across on the first sync, and a pairing whose both halves have aged out is forgotten rather than treated as a deletion. Apple keeps a completed copy of every past occurrence of a recurring reminder, so without this the first sync would push years of history into Google.
- `google.tokenStorage`: `file` stores refresh tokens as 0600 files under `~/.config/remtasks/tokens/`; `keychain` uses the macOS Keychain (may prompt after rebuilds when running from launchd); `1password` keeps them in 1Password (see below).

## Keeping credentials in 1Password

With `"tokenStorage": "1password"`, remtasks stores each account's refresh token as a 1Password "API Credential" item named `remtasks <account>` and never writes tokens to disk. Access tokens are minted per run and held in memory only. The OAuth client JSON can live in 1Password too. Requirements: the [1Password CLI](https://developer.1password.com/docs/cli/) (`brew install 1password-cli`) with the desktop app integration turned on (1Password > Settings > Developer > Integrate with 1Password CLI).

```json
"google": {
  "clientSecretFile": "op://Private/remtasks google client/credential",
  "tokenStorage": "1password",
  "onePassword": { "vault": "Private", "itemPrefix": "remtasks" }
}
```

- To move existing tokens: run `remtasks migrate-tokens --to 1password` **before** changing `tokenStorage`, then update the config. Add `--keep` to leave a copy in the old backend.
- To store the OAuth client JSON: create an API Credential item in the vault (here titled `remtasks google client`) and paste the file's contents into its `credential` field, then point `clientSecretFile` at it with an `op://vault/item/field` reference and delete the file.
- The 1Password CLI asks for authorization per process, so the background agent runs `remtasks daemon`, a single long-lived process that reads the vault once at startup and keeps tokens in memory. Expect one authorization prompt after login, not one per sync. If 1Password is locked at startup, the daemon logs an error and retries on the next cycle. After `remtasks auth`, restart the agent (`launchctl kickstart -k gui/$(id -u)/net.gitman.remtasks`) so it picks up the new token. `remtasks doctor` checks that the CLI can reach the vault.
- `onePassword.opPath` overrides the CLI location if it is not in `/opt/homebrew/bin` or `/usr/local/bin`.

## Use

```bash
remtasks lists            # show every Reminders list, its group, and where it will sync
remtasks google-lists     # show the Google Tasks lists in each account
remtasks google-tasks Legal --all   # show the Google tasks paired with one Reminders list
remtasks auth personal    # browser sign-in for each account key in your config
remtasks auth work
remtasks doctor           # check permissions, credentials, and the Reminders database
remtasks sync --dry-run   # print every change the first sync would make
remtasks sync             # do it
remtasks status           # recent runs and pairing counts
remtasks daemon           # run continuously, syncing every 5 minutes (what the agent runs)
remtasks install-agent    # keep 'remtasks daemon' running in the background via launchd
remtasks install-agent --display-name "My Sync"   # name shown under Login Items > Allow in the Background
```

The first time it touches Reminders, macOS asks for permission. The permission is attributed to the app that launched remtasks, so when you run it from Terminal, iTerm, or Warp, that app is what appears under System Settings > Privacy & Security > Reminders. Terminals embedded in other apps (editors, the Claude desktop app) usually lack a Reminders usage description and are refused silently with no dialog; use a standalone terminal, or install the launchd agent, which is prompted for as `remtasks` itself. If a dialog was dismissed, re-trigger it with `tccutil reset Reminders <bundle id>`.

Google's Tasks API allows roughly 300 writes per minute per user. remtasks paces writes and backs off on quota errors, so a large first sync simply takes a few minutes.

**Full Disk Access is tied to the binary's signature.** Run `scripts/make-signing-identity.sh` once: it creates a self-signed code-signing certificate in your login keychain (macOS asks for your password to trust it), and `scripts/install.sh` then signs every build with it, so the grant survives reinstalls. Without that identity the installer falls back to an ad-hoc signature, which changes with every build; you would then have to remove and re-add the binary under Full Disk Access after each reinstall. Until it is granted, the agent falls back to cached group membership and skips subtask nesting, and `doctor` reports it.

The launchd agent cannot read the Reminders database unless you grant **Full Disk Access** to the `remtasks` binary (System Settings > Privacy & Security > Full Disk Access, press +, and pick `~/Library/Application Support/remtasks/Apple Reminders & Google Tasks Sync`; press Cmd+Shift+G in the file dialog to type the path). Without it the agent still syncs, using the group membership cached by the last run that could read the database (any `remtasks lists` or `sync` from a terminal), but subtasks created since then stay flat in Google until a terminal run or Full Disk Access.

Logs go to `~/Library/Logs/remtasks/`.

## How it works

Each run, per mapped list:

1. Read all reminders (EventKit) and all tasks (Google Tasks API) for the pair. Subtask parents and group membership come from the Reminders app's own SQLite store, read-only, because EventKit does not expose them.
2. Compare both sides against the stored pairing state. Each pairing remembers a fingerprint of the synced fields (title, notes, due day, completion). A side has "changed" when its fingerprint differs from the stored one, so a write made by remtasks itself never echoes back.
3. Decide, in pure code with no I/O (`SyncPlanner`):
   - changed on one side only: push to the other;
   - changed on both: the later `lastModifiedDate` / `updated` wins;
   - missing on one side: delete on the other, unless the surviving side was edited after the last sync, in which case it is re-created;
   - never paired: pair by identical title and due day if a twin exists, otherwise create;
   - recurring reminder that moved to a later date after its Google twin was completed: new Google task for the new occurrence, old one stays completed;
   - Apple hierarchy differs from Google's: move the Google task under the right parent.
4. Apply the plan, updating the state after every successful write.

State lives in `~/.config/remtasks/state.sqlite`. Delete it to start over; the next run re-pairs by title instead of duplicating.

## Development

```bash
swift build
swift run remtasks-tests     # unit tests for the planner, model, and config
swift run remtasks lists
```

Tests live in `Sources/remtasks-tests` as a plain executable so they run on Macs with only the Command Line Tools installed (no XCTest).

## Contributing

Issues and pull requests welcome. Please keep the planner pure and covered by tests, and never commit config, tokens, or state files.

Wanted: notarized builds under an Apple Developer ID so users need neither Gatekeeper workarounds nor a local signing identity.

## License

MIT. See [LICENSE](LICENSE).
