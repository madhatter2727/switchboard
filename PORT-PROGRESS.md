# Port progress (started Oct 18 2026 ~4:25 PM ET)
Backup: ~/Projects/model-picker-backup-20261018-port
- Copied Ask My Mac's file logic (PathGuard, UndoLog, ActionPlan/ActionCenter, FileTools2) into mac/Sources/ModelPicker/Port/
- M1-M3 code written (undo, trash/copy/folder, open) with ported ActionCenter/UndoLog; installing + testing.

## M1 Undo Last Action - tested-works
Saved log (~/Library/Application Support/Model Picker/undo.json, same logic as Ask My Mac). Menu items: Edit > Undo Last Action and menu-bar icon > Undo Last Action. In-chat: type "undo". Undo button under every approved action. Tested in sandbox: move, copy, mkdir, rename, trash all reversed; "undo" typed in chat reversed a move.
## M2 Trash / copy / make folder - tested-works
Same planner as Ask My Mac (collisions get " 2", never overwrite, refuses Library/hidden/system, no permanent delete). Raptor drove move/copy/mkdir/trash with Approve; Deny changed nothing. Compared with Ask My Mac --selftest-move: identical preview and undo record.
## Code written for M4-M9 (Oct 18 ~4:30 PM): calendar/reminders tools, settings panel, instant commands, quick-chat popover, photo button, mic button. Testing next.

## Final status (Oct 18 ~4:35 PM ET)
| # | Feature | Status |
|1| Undo Last Action (log, Edit menu, menu-bar item, "undo" in chat, Undo button) | tested-works |
|2| Trash / copy / make folder / move / rename with Approve | tested-works (Raptor + CLI, sandbox) |
|3| Open file/app/link | tested-works (open_item + "open <path>" instant) |
|4| Reminders list, calendar add-event with Approve, calendar choices | built-but-untested: needs Calendar + Reminders permission click on the Mac |
|5| Settings screen (model/Auto, calendars, Photo Reader, voice, safety) | built; opens and renders (calendar list waits on permission) |
|6| Instant commands (find, open, undo; screenshots move; calendar) no model | find/open/undo tested-works; screenshots-move and calendar built-but-untested (Desktop/Calendar permission) |
|7| Quick chat popover in menu bar (left-click icon; right-click = menu) | tested-works (instant command typed in popover) |
|8| Photo Reader | tested-works (direct + via Raptor) ; 📷 file picker button built-but-untested (needs click) |
|9| Hold-to-talk voice | built-but-untested: needs Speech Recognition + Microphone permission click |
Install now signs with a stable identity so macOS permissions survive updates.
Test files: ~/Projects/model-picker/test-sandbox. Screenshots: ~/Projects/model-picker/bench/port/

## Round 2 permission tests (Oct 18 4:35-4:50 PM ET)
- Calendar read + calendar choices in Settings: tested-works (calendar permission granted; Work, Home, Birthdays, US Holidays listed; Oct-Dec events read).
- Add calendar event approval card: tested-works (card only, nothing created). FOUND+FIXED a bug copied from Ask My Mac: times like 2026-12-30T10:00:00 were read as an all-day event the day before. Model Picker fixed (Port/CalendarWrite.swift); Ask My Mac NOT changed and still has it.
- Reminders: needs-Tara (Reminders "Allow" dialog still on screen, unanswered).
- Voice: Speech Recognition granted; Microphone still notDetermined (its prompt is queued behind the Reminders dialog) -> needs-Tara.
- Screenshot-move instant command: needs-Tara (Desktop folder prompt queued behind Reminders dialog; nothing moved).
- Photo picker opens: tested-works; Photo Reader backend tested earlier.

## Round 3 (Oct 18 4:56-5:03 PM ET)
- Reminders: tested-works (full access; "No incomplete reminders.").
- Voice: tested-works as far as possible: Mic + Speech authorized, recorder starts (listening=true), silence gives "Didn't catch that" like Ask My Mac. Actual speech-to-text not tested (no voice).
- Screenshot-move: Desktop access works; approval card verified on her real screenshot, DENIED, nothing moved or created.
- Ask My Mac date bug FIXED (CalendarWrite.swift), backup ~/Projects/ask-my-mac-backup-20261018c, reinstalled with stable signing. Parsed 2026-12-30T10:00:00-10:30:00 = Dec 30 10:00-10:30 AM, not all-day (before fix: all-day Dec 29). Its permissions reset once by the reinstall.

## Oct 21 2026 ~10:10-10:40 AM ET: chat lock + tools for every tool-capable model (Tech Demos)
Backup first: ~/Projects/model-picker-backup-20261021 (source + installed .app). Only web/app.js changed (+ bench/toolcheck/ test files).
Root causes:
- Bug 1 (Auto switched models mid-chat): send() ran autoSwitch -> autoRoute on EVERY message, so a follow-up without file words went to Bonsai 4B. Also the agent history sent to the model dropped earlier tool results, so even the same model could not see a file it had already read.
- Bug 2 (manual Raptor "can't access folders"): the Agent mode checkbox starts unticked and nothing ever ticked it on a manual pick; only Auto's files route did. Tools are only sent when that box is ticked.
Fixes:
- Auto picks once on the first message, stores chat.lock {engine, model, why, agent} in the chat file, and reuses it for every later message (also after reopening the chat). Label: "Auto picked Raptor (files or calendar) · locked for this chat"; header "Auto · locked to Raptor for this chat". New chat = fresh pick. Choosing Auto again mid-chat clears the lock (next message picks and locks). Picking a model by hand still turns Auto off for that chat.
- Agent mode (file/folder/calendar tools) is ON by default for any tool-capable model, both manual picks and Auto locks; you can still untick it per chat (remembered in the chat).
- Agent requests now replay earlier tool calls + results, so follow-ups use file contents already read.
- Thinking switched off for Bonsai/Spark engines (chat_template_kwargs enable_thinking:false), Raptor reasoning_effort none.
- If a model returns an empty reply right after a tool result, retry once with a short "answer now" note (Gemma 4 on Ollama 0.30.11 does this every time).
Tool-calling check (one tool call each, one model at a time, via proxy 7777; bench/toolcheck/results.jsonl):
- Tools ON (passed): Raptor 0.6, Spark X2.5 (Osaurus and port 8095), Bonsai 2 4B, Bonsai 2 9B, gemma4:e2b, ornith:9b, ornith-agent (calls tools but guessed a wrong path once), qwen2.5-coder:7b (writes the call as text; app parses it).
- Tools OFF: gemma2:2b (Ollama: "does not support tools").
- Bonsai 2 27B: kept agent-capable from the Oct 18 bench (passed on port 8096); Osaurus copy timed out today (too big with other models loaded; memory dropped to 10%, Osaurus restarted to free it).
Verified in the real app (selftest convo mode, WebView screenshots in bench/toolcheck/): A Auto desktop file read -> Raptor, follow-up synopsis still Raptor using the file text; B manual Raptor listed a folder and read a file with no box ticking; C Auto plain chat stayed Bonsai 4B for the follow-up; D manual Spark and E manual gemma4 listed a folder; F qwen2.5-coder listed a folder.
