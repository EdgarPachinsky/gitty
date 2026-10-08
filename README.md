# Gitty

A calm, friendly Git companion for desktop (macOS, Windows, Linux), built with Flutter.

## Getting started

Requires Flutter 3.32+ (Dart 3.8+) and Git.

```bash
./setup.sh          # macOS / Linux  (Windows: ./setup.ps1)
flutter run -d macos   # or -d windows / -d linux
```

`setup.sh` runs `flutter create` to generate the native runner folders around the existing
code (existing files are never overwritten) and then `flutter pub get`.

### GitHub account

Gitty signs in with GitHub's **Device Flow** using its built-in OAuth App
(client id `Ov23liNSfJZZX9slckxg`, Device Flow must be enabled in the app's settings).
No client secret is needed; the token is stored in the OS keychain.

- Override the app: `flutter run -d macos --dart-define=GITHUB_CLIENT_ID=<id>`
- Simulated sign-in (no network): `--dart-define=GITHUB_CLIENT_ID=`

Once connected, Gitty lists your repositories (clone / add origin) and — only when your own
git credentials don't cover a `https://github.com/...` remote — retries fetch/pull/push/clone
with the account token (passed via `GIT_CONFIG_*` env vars, never on the command line or in config).

### Any folder can be added

Add any folder, empty or not. If it isn't a Git repository yet, Gitty offers **Initialize Git**
(`git init`, `main` unless `init.defaultBranch` is set), then asks you to **Add origin** — paste a URL
pick one of your GitHub repositories, or **create a new GitHub repository** right in the dialog
(owner = you or one of your orgs, private by default, created empty) — it's added as origin and,
if you already have commits, pushed right away. If the remote already has commits and the folder has none,
Gitty checks out the remote branch (your existing files stay; conflicting ones are never overwritten).

### Who's committing (per repository)

Each repository shows a **Who’s committing?** card. If Git has no name/email, the card asks for them
(prefilled from your GitHub account, with GitHub's private no-reply email). Otherwise it shows who you
commit as and where that comes from. Saving always uses `git config --local`, so it lives only in that
repository's `.git/config` and your global Git settings are never touched. If a commit fails because
the identity is missing, Gitty asks right there and then commits.

### Repository list

- **Search** (⌘F / Ctrl+F) by title, folder, path, branch or host ("GitLab").
- **Pin** a repository (the button next to ⋮) to keep it in a **Pinned** section at the top; everything else
  is listed below. Pins are saved with the repo list.
- **Host filters**: small logo buttons next to the "Your repositories" title (GitHub, GitLab, Bitbucket, Azure DevOps, other Git
  servers, no remote), each with a count. Click one or several to show only those; click again to undo.
- **Pinned** and **All other repositories** are expandable panels; Gitty remembers which ones you folded.
- **⋮ menu** on each card: Open, **Rename in Gitty…** (a custom title just for Gitty; the folder keeps its name
  and the card shows only the parent folder), Show in Finder, and **Remove from Gitty** (your files stay put).
- **Host logos** (GitHub, GitLab, including self-hosted, Bitbucket, Azure DevOps, or a generic Git mark) from
  the remote URL, via `font_awesome_flutter`. Click a logo to open the repository in your browser.
- **Copy branch name** button next to the branch in the repository header.
- **"Not linked"**: if your branch has no upstream but the same branch exists on the remote (e.g. a folder
  connected after `git init` + `remote add`), Gitty says so and offers **Link them**
  (`git branch --set-upstream-to`) instead of "Publish".

### Revert (with undo)

**Revert all** (next to Stage all) and a **revert** button on every file put changes back to your last commit,
and remove new files. Each asks first, explaining per file what will happen. Before reverting, Gitty keeps a
backup (`git stash push --include-untracked`, labelled "Gitty backup…"), so the snackbar offers **Undo**
(`git stash pop --index`). In a repository without commits no backup is possible, and the dialog says so.

### "Git is locked" (index.lock)

If git reports `Unable to create '…/.git/index.lock': File exists`:

1. Gitty retries once after a moment, because another program (IDE, terminal) is often just finishing.
2. If the lock is still there, a dialog explains it and checks, on macOS and Linux, whether anything still has the
   file open (`lsof`) or a git process is running in that repo (`pgrep`).
3. Only when nothing is using it does Gitty offer **Remove leftover lock & try again**, which then re-runs the action.

Gitty also removes a lock left by one of its own commands if it has to stop it on a timeout. Staging has a
10-minute limit, since big trees can take a while.

### Always in sync

- **With your folders.** Every repository Gitty shows is watched on disk (`Directory.watch`, recursive on
  macOS/Windows, polling on Linux). New, edited or deleted files, and git commands run in a terminal or IDE,
  show up within about a second. Events are batched, so something like `npm install` doesn't flood it. Gitty also
  refreshes when you switch back to it.
- **With origin.** The open repository is fetched right away and then every minute. The others are fetched on the
  background schedule from Settings. Gitty compares remote branches before and after each fetch. When someone
  pushes to **your branch**, or to the branch **yours grew from** (e.g. `main`), you get a notice like "Ana pushed
  3 new changes to “main”…" with a **Show** button. The repository screen then shows "“main” has 3 new changes
  your branch doesn’t have yet" with **Bring them in**, which merges them without rewriting anything.

### Branch family tree

**Switch branch** draws your branches as a tree: the trunk (main) at the top, lines to every branch that grew out
of it, a "You are here" marker, and a plain sentence on each ("Grew from main 3 days ago. Has 2 changes of its
own. main got 1 change since."). Parents come from, in order: what Gitty recorded when it created the branch
(`branch.<name>.gittyParent` in the local config), the branch's "Created from" note in git's own history, the
first time you switched to it, and finally the commit history itself. Branches whose parent came from the
commit history say "Probably grew from…".

### .gitignore helper

Each repository shows an **Add a .gitignore** card (or a compact summary when one exists). It detects
the project type (Flutter, Node, Python, Swift, Go, Rust, Java, .NET, PHP, Ruby) and suggests rules for
this OS, secrets, editors and logs. Every group of rules comes with a plain-language reason, and a live
preview shows which items would disappear from your changes (`git ls-files --ignored --exclude-from`)
before anything is written. Existing files are only ever appended to, never rewritten.

### AI commit messages — local or cloud

**Settings → Commit messages → AI engine** picks who writes "Generate with AI" messages:

| Engine | What you need | Where your diff goes |
|---|---|---|
| **Local (Ollama)** — default | [Ollama](https://ollama.com) + `ollama pull llama3.2` | Nowhere — stays on this computer |
| **Claude** | An Anthropic API key (default model: Claude Haiku 4.5; the model list is loaded from your key) | Anthropic |
| **OpenAI-compatible** | Server address + key (OpenAI, OpenRouter, Groq, …) — or a local server like LM Studio (`http://localhost:1234/v1`, no key) | That server |

API keys live in the system keychain. Only the staged diff is sent, and only when you press the button.
If a cloud engine fails, Gitty falls back to local Ollama (toggle), then to an offline draft — the button
always works.

**Speed.** For local models Gitty asks Ollama (`/api/show`) whether the model "thinks" and turns that off
(`think: false`), or to its lowest level (`"low"` for gpt-oss). It caps the answer length, streams text into
the message box as it's written, keeps the model loaded (`keep_alive: 30m`), and warms it up as soon as
something is staged. It also sends only a small diff: lockfiles, generated code and IDE files are left out,
each file is capped and the total is about 6 KB (16 KB for cloud engines). Claude Opus/Sonnet get
`output_config.effort: "low"`; Haiku is fast as is. Tip: small non-thinking models (`llama3.2`,
`qwen2.5-coder:3b`) are the quickest for commit messages.

**Managing local models.** In Settings → Local you can **Install** the suggested models, or any model by
name, without a terminal. You get a live progress bar with size, speed and time left, plus **Pause/Resume**
(Ollama keeps partial downloads) and **Stop**. Installed models have a **Delete** button, both in the
suggestions and next to each entry in the model dropdown (`/api/pull`, `/api/delete`).

Every answer goes through a clean-up step (no "<blank line>" placeholders, labels, markdown,
or "This commit adds…" narration; short subject, body wrapped at 72).

## Architecture

```
lib/
  main.dart, app.dart            App bootstrap (storage → ProviderScope → MaterialApp)
  core/                          Theme, friendly errors, shared widgets, OS launcher
  services/                      No UI code — pure service layer
    git/                         GitCli (system git), GitService, status parser, repo scanner
    ai/                          CommitMessageService: Ollama engine + offline draft engine
    auth/                        GitHostingProvider interface, GitHub device flow, demo provider
    storage/                     Hive (JSON boxes): settings, tracked repos, local analytics
    service_providers.dart       Riverpod wiring for all services
  features/
    onboarding/                  Welcome → connect GitHub → add repositories
    dashboard/                   Repository list, add/scan/clone, background fetch
    repository/                  Repo view: big actions, changes, commit box, sync banner, insights
    settings/                    Theme, commit style, Ollama, sync, accounts
    account/                     GitHub account state + connect card
```

- **Git**: runs the system `git` binary, so config, hooks, credential helpers and SSH keys
  behave exactly like the terminal. Prompts are disabled (`GIT_TERMINAL_PROMPT=0`) and every
  failure is mapped to a friendly message with a "Details" view.
- **Providers**: add GitLab/Bitbucket/Gitea by implementing `GitHostingProvider`.
- **Privacy**: analytics are local-only (Hive box `analytics`), nothing is uploaded.
- **macOS**: the App Sandbox is disabled (see `macos/Runner/*.entitlements`) so Gitty can run
  `git` and access repositories anywhere, like other Git clients.

## Tests

```bash
flutter test
```
