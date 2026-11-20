# Teaching Hub

A native macOS planner for teachers. Keeps lesson plans, resources, and PowerPoints together in one iCloud folder — every lesson is a folder containing a `lesson.md` plus whatever files go with it. The app reads that folder tree and shows a calendar.

Built on top of [Markdown Calendar](https://github.com/jrowing/markdown-calendar), with teacher-specific features: class timetables and term dates, scheduling operations (pull forward / bump back, singly or cascading), long-term class and year views, and Apple Calendar sync.

## Status

**All four planned phases built.** Lesson folders with resources, class-timetable-aware scheduling, long-term views (class and year), and Apple Calendar sync.

### Phase 1 — Folder-per-lesson with resources panel

- Reads a folder tree recursively looking for `lesson.md` (or any `.md` with a `date:` field)
- Collects sibling files as "resources" attached to that lesson — PowerPoint, PDF, images, worksheets, anything
- Shows resources in the detail panel with proper icons; click one to open in its default app (Keynote, Preview, etc.)
- Creates new lessons as folders (`YYYY-MM-DD-slug/lesson.md`) rather than flat files
- Defaults to `~/Library/Mobile Documents/com~apple~CloudDocs/Teaching/` (iCloud Drive) on first launch

### Phase 2 — Class timetables + scheduling

Define each class's weekly schedule in a small config file inside `<Teaching>/classes/<slug>.conf`. The slug must match the top-level folder name for that class's lessons (so `year-10.conf` corresponds to `year-10/`).

```
# classes/year-10.conf — Year 10 Science timetable
name: Year 10 Science

# One period per line: <day> <start>-<end> [room]
period: mon 09:30-10:30 room-203
period: wed 11:10-12:30 room-203
period: fri 13:10-14:30 room-lab-2
```

Day codes: `mon tue wed thu fri sat sun`. Lines starting with `#` are comments. Edit in any text editor, Teaching Hub picks it up on next folder reload.

Once a class has a config, lesson cards gain two scheduling actions in the `⋯` menu:

- **Pull forward one slot** — move the lesson to the previous teaching slot for its class
- **Bump back one slot** — move the lesson to the next teaching slot

Both rename the lesson's folder to match the new date (if its name starts with a `YYYY-MM-DD` prefix) and update `date:` / `end:` inside `lesson.md`. If the class has no config, those menu items are hidden.

**Editing timetables in the app.** The Settings sheet (⌘,) lists every loaded class and its periods. Click the pencil to edit a timetable in a small form (day, start, end, room); **Add timetable for a class…** offers every lesson folder that has no timetable yet; **Fill from lesson history** looks at a class's existing lessons and proposes any weekday + start time that repeats. Saving rewrites the `.conf` file (comments in it are replaced). The document icon opens the raw `.conf` in your text editor, and "Open classes folder" jumps to the folder in Finder.

**Term dates.** An optional `terms.conf` in the Teaching folder (`term: <name> | <start> | <end>` and `holiday: <date> | <reason>` lines) makes pull forward / bump back skip weekends, holidays and out-of-term dates.

**Cascading shifts.** The lesson detail panel's scheduling menu also offers *Pull forward cascade* and *Bump back cascade*, which move this lesson and every later lesson for the class by one slot — handy when a day is lost and everything after it needs to slide.

### Phase 3 — Long-term views

Two new view modes beyond Calendar / Week / Timeline:

**Class view (⌘4)** — pick one class from the top-right menu, see all its lessons grouped by scheme-of-work (the topic folder). Each topic section shows lesson count, date range, and an expandable list of lessons. Summary tiles at the top show total lesson count, topic count, and overall span. Click any lesson to open it in the editor.

**Year view (⌘5)** — GitHub-contribution-graph style overview. One row per class, 40 columns for the weeks of the academic year (Sep – June). Each cell is colored by the class's tag, with opacity scaled by lesson count. Hover for the week's topic names; click a non-empty cell to jump to that week in Week view. The class name on the left is itself a button that jumps to Class view for that class. Previous / next buttons navigate between academic years.

The detail panel hides automatically in Class view and Year view since both are standalone overviews — the day-based panel would just be noise.

### Phase 4 — Apple Calendar via EventKit

- One-way sync from the Teaching folder into a dedicated calendar called **Teaching Plan** in your iCloud account
- Shows up on your Mac, iPhone and iPad through standard iCloud Calendar sync — no extra setup on iOS devices
- Events include the lesson title, date/time, location (class slug), notes (body + requirements as `☐` checkboxes + resource list), and a `file://` URL pointing at the lesson folder (clicking in Calendar.app on Mac opens the folder in Finder)
- Debounced auto-sync when lessons change (2 s after the last edit, to avoid thrashing EventKit)
- Opt-in: ⌘, (Settings) → "Enable sync to Apple Calendar". First use prompts for Calendar permission; Teaching Hub only writes to its own calendar, never reads your other events (macOS 14+ uses write-only access API)
- "Remove all synced events" button in Settings for a clean slate

### Google Classroom

Post a lesson to Classroom from the lesson card's `⋯` menu → **Post to Google Classroom…**

- **Only the `## Students` section of `lesson.md` is sent** (plain-text tidied), plus any lesson files you explicitly tick. Teacher notes, requirements and everything else stay on your Mac. The text is shown in an editable box first; edits there don't change `lesson.md`.
- Post as an **Announcement** or a **Material**, as a draft, immediately, or scheduled for a time you choose.
- Ticked files are uploaded to your Google Drive and attached view-only.
- The post is recorded in the lesson's front matter (`classroom_post`, `classroom_course`, `classroom_kind`). Later you can update the post's wording; Classroom doesn't allow changing attachments afterwards, so changed files need a new post.
- The course you choose is remembered per class folder.

Setup (once): Settings → Google Classroom → paste an OAuth client ID and secret (Desktop app type, from your own Google Cloud project with the Classroom and Drive APIs enabled; steps are in the Settings sheet). Sign-in opens your browser; the refresh token is kept in the macOS Keychain. Your school's Workspace admin may need to allow the app.

Example lesson with a student-facing section:

```markdown
## Students

Today we looked at Newton's second law. Please read pages 42–45 and try the questions on the worksheet.

## Requirements

- trolleys × 4
```

### Possible future work

- In-app term-dates editor (currently edit `terms.conf` by hand)
- Key-stage overlay in Year view (multiple classes side-by-side at the same timescale for cross-class planning)

## Folder convention

```
~/iCloud Drive/Teaching/
├── year-10/                  # class (top-level folder)
│   ├── forces/               # scheme of work (topic grouping)
│   │   ├── 2026-09-05-intro/
│   │   │   ├── lesson.md
│   │   │   ├── slides.pptx
│   │   │   └── worksheet.pdf
│   │   ├── 2026-09-07-balanced/
│   │   └── 2026-09-09-newton/
│   └── waves/
├── year-11/
└── year-13-physics/
```

- Any file named `lesson.md` (or any `.md` with a `date:` field) is a lesson
- Every sibling file of that `lesson.md` becomes a resource
- Top-level folder under `Teaching/` is the class
- Second-level folder is the scheme of work (just a label; the app doesn't require it)

Example `lesson.md`:

```yaml
---
title: Intro to Forces
date: 2026-09-05 09:30
end: 2026-09-05 10:30
tags: [year-10, physics]
---

Hook: push a trolley with different masses, see what changes.

## Requirements

- trolleys × 4
- masses × 8
- stopwatches × 4
- worksheet (printed × 28)
```

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9+ (install via `xcode-select --install` — full Xcode not required)

## Build

```bash
./make-app.sh /Applications   # compile and install
```

That produces `Teaching Hub.app`, installs it to `/Applications`, and the app appears in Spotlight and Launchpad with the book-and-calendar icon.

To build without installing:

```bash
./make-app.sh                 # produces ./TeachingHub.app in the repo
./make-app.sh ~/Applications  # installs to your user Applications folder
```

To produce a `.dmg` for distribution:

```bash
./make-dmg.sh --pretty
```

Output: `TeachingHub-1.1.0.dmg`.

## Architecture

```
Sources/TeachingHub/
├── TeachingHubApp.swift          # @main, AppDelegate, menu commands
├── ContentView.swift             # root, welcome screen, sheet management
├── MainView.swift                # toolbar + 3-pane layout
├── MonthView.swift, WeekView.swift, TimelineView.swift
├── ClassView.swift               # Phase 3 — one class, grouped by topic
├── YearView.swift                # Phase 3 — contribution-grid overview
├── DetailPanel.swift             # right-hand selected-day panel + resources rows
├── RequirementsPanel.swift       # left-hand weekly summary
├── EntryEditor.swift             # create + edit sheet
├── SettingsSheet.swift           # ⌘, settings (terms, classes, calendar sync)
├── CalendarSync.swift            # Phase 4 — EventKit sync engine
├── ClassConfig.swift             # Phase 2 — class timetable parser + slot helpers
├── ClassEditor.swift             # in-app timetable editor, .conf writer, history inference
├── ClassroomClient.swift         # Google sign-in (PKCE), Drive upload, Classroom posts, ## Students extraction
├── ClassroomPushSheet.swift      # "Post to Google Classroom" sheet
├── TermConfig.swift              # terms.conf — term dates + holidays
├── StatusBarController.swift     # NSStatusItem menu-bar tray
├── Entry.swift                   # Entry + Resource model
├── EntryStore.swift              # vault wrapper, recursive scanning, CRUD, scheduling ops
└── DateUtil.swift, Markdown.swift, Parsing.swift, TagColor.swift
```

~6,400 lines of pure SwiftUI + AppKit. No webview, no Electron.

File watching uses `DispatchSource.makeFileSystemObjectSource` on the folder's file descriptor with a 400 ms debounce. The menu-bar tray uses `NSStatusItem` + AppKit `NSMenu`, subscribed to `EntryStore.$entries` via Combine. Folder access uses normal `FileManager` APIs — the path is stored in `UserDefaults` for restore across launches. The app is not sandboxed.

## Relationship to Markdown Calendar

Teaching Hub started as a fork of Markdown Calendar. The underlying calendar/scanning engine is shared heritage; from here the two projects diverge.

Markdown Calendar stays as a general-purpose tool anyone can use for any folder of dated markdown files. Teaching Hub makes teacher-specific choices (class as a first-class concept, folder-per-lesson, resource attachments, timetable and term awareness, Apple Calendar sync).

If you just want a calendar over markdown files without the teaching-specific features, use [Markdown Calendar](https://github.com/jrowing/markdown-calendar) instead.

## License

MIT — see `LICENSE`.
