# Privacy Policy

remtasks (Apple Reminders & Google Tasks Sync) is an open-source program that runs entirely on your own Mac.

- **What it accesses.** With your permission, it reads and writes your Apple Reminders through macOS, and your Google Tasks through the Google Tasks API using OAuth credentials you create in your own Google Cloud project.
- **Where your data goes.** Reminder and task content moves only between your Mac, Apple's iCloud (via the Reminders app), and Google Tasks in the Google accounts you sign in to. Nothing is sent to the author or to any third party.
- **What is stored locally.** A pairing database (which reminder corresponds to which task), your configuration, and log files, all under your home folder. Google refresh tokens are stored where you configure: a permission-restricted file, the macOS Keychain, or 1Password.
- **Google user data.** The program's use of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements. It uses Google Tasks data solely to keep your tasks in sync with your reminders.
- **No analytics.** The program collects no telemetry and has no server component.
- **Revoking access.** Remove the program's access at any time at https://myaccount.google.com/permissions, or run `remtasks auth <account> --sign-out`.

Questions: open an issue at https://github.com/dgitman/apple-reminders-google-tasks-sync/issues.
