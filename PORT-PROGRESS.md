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

## Oct 21 2026 ~10:30-11:15 AM ET: no size limits on reading (Tech Demos)
Backup first: ~/Projects/model-picker-backup-20261021b (source, installed .app, old ~/Models/bonsai2/start.sh).
Root cause of "cut off at 'Local is a second phase fr'": the agent's read_file_text (Tools.swift) returned only the first 4000 characters (and only plain text: PDFs/Word failed). On top, the window cut each tool result to 6000 characters and to 4000 when re-sending history. The ported Ask My Mac reader (Port/FileToolsRead.swift, PDF/Word) also clipped at 4000 and was not even used.
Fix (no hard caps left in reading, tool results, history or listings):
- read_file_text returns the WHOLE file; text, Markdown, code, PDF (all pages, PDFKit), Word .docx/.doc, RTF/RTFD, ODT, HTML (same extraction as Ask My Mac/One Space). iWork files get a plain "export to PDF/Word first" message. Optional offset to jump.
- If the file fits the model's memory it goes in whole. If not, the window reads it in parts that fit (same model), takes notes on every part, combines the notes (repeats if needed), and gives the model the notes plus the exact opening and exact ending. The result says plainly that the file was bigger and that nothing was skipped. Works for any size.
- Tool results and history are never shortened. If a long chat no longer fits, the oldest tool results (then oldest turns) are replaced by a visible note saying they were not re-sent (still saved in the chat).
- Lists page instead of cutting: list_folder 500 per page, search_files 200, files-by-date 300, with a MORE note; the window fetches further pages by itself while they fit. Calendar events, reminders, instant find results: no cap. Step boxes show "show all N characters".
- Pasted text longer than the model can hold is read in parts the same way.
- Answer length: max_tokens set from the free context (up to 16k) instead of the engine default (Osaurus defaulted to 2048). Photo Reader answers up to 4096 tokens (was 512). Agent steps 8 -> 30 per message (then it pauses and says "continue").
- Guessed paths like /Users/user/... or /Users/.../ are mapped onto Tara's home.
- Context: Bonsai 2 4B/9B now -c 65536 -np 1 with q8 KV cache (was 8192 shared by 4 slots); Ollama already 65536 (OLLAMA_CONTEXT_LENGTH, q8 KV); Raptor/Spark budgeted at 32768 (Osaurus has no setting; model supports far more); Bonsai 27B 16384; gemma2:2b 8192.
Results (read-only reads; test files test-sandbox/docs/big-60kb.txt and big-1mb.txt):
- Raptor (Auto): Desktop Hermes guide -> quoted the real last sentence "Product UI and model names change quickly — re-check official Hermes docs on install day." 60 KB: exact last line, 1 read, ~30 s. 1 MB: correct last line (dropped the "FINAL LINE:" label), read in parts, ~6.5 min.
- Bonsai 4B: whole Desktop file delivered (7,442 chars) but it quoted the bold "bottom line" sentence instead of the true last one; 60 KB exact; 1 MB correct, ~12.5 min.
- Gemma 4 E2B: same Desktop behaviour as Bonsai ("ECC and Grok Build stay separate lanes."); 60 KB exact; 1 MB: see below.

## Oct 21 2026 (afternoon): "open <doc> in <folder>" fix
Bug: "open the gdd document in my test folder" (Auto) opened ~/Desktop/Tabled/claude-fable-builds/claude-fable-builds-MASTER.pdf.
Root cause: PreRouter sent the whole phrase "the gdd document in my test folder" to FileTools.searchFiles, which ran a Spotlight
*content* query over all of ~ (any file whose text contains those words), ranked PDFs first, and topDocument() opened hit #1. No folder scoping, no filename matching, no ambiguity check.
Fix: new Port/DocFinder.swift. Parses name vs folder ("in/on/inside/under/from/within"), resolves the folder case-insensitively
(Desktop, home, Documents, Downloads; chains like "test folder on my desktop"), walks only that folder (no cap, skips hidden/node_modules/.git/Library/.app insides),
matches the name against file basenames only (token/substring, case-insensitive; type words like pdf/word/spreadsheet filter extensions).
Exactly 1 match -> open. Several -> list with Open buttons, opens nothing. None / unknown folder -> plain note, then hands off to the model with file tools
(folder path passed as a hint). Not a simple open (and/then/summarize/?/long phrase) -> straight to the model. Auto now routes open/doc/document to Raptor+tools.
Also: search_files tool no longer returns mdfind log lines as fake paths. Dry run: `--dry-run` arg or MP_DRYRUN=1 (no files opened).
Tests (dry run, GUI selftest + CLI --preroute): her sentence -> ~/Desktop/Test/01-GDD.md; hermes -> hermes-mac-mini-desktop-setup.md; budget -> note + Raptor listed the folder and said it isn't there;
"open the gdd document" (no folder) -> 6 GDD files listed, none opened; "open the gdd file and summarize it" -> model. Backup: ~/Projects/model-picker-backup-20261021c.

## 2026-10-21 ~12:40 PM ET (Tech Demos) — Tara's 5 reports
Backup before work: ~/Projects/model-picker-backup-20261021d. Commits 8784a45, a58220e, (delete-all), (menu bar), b2eff93 pushed to private madhatter2727/model-picker.
1. Create/edit files: new tools create_file (txt/md/docx/rtf/html/code, no approval, Undo moves it to Trash), edit_file (append/prepend/replace/overwrite; Approve card; backup in ~/Library/Application Support/Model Picker/backups; Undo restores), pages_new_document (AppleScript: new blank Pages doc + body text, optional save .pages). Source Port/FileWrite.swift. Tested: Raptor + Bonsai 4B create → edit (Approve) → Undo in test-sandbox; docx create/edit/undo via --tool. Pages: Raptor called the tool for Tara's exact sentence; macOS Automation prompt ("Model Picker wants access to control Pages") appeared; NOT yet allowed (status notAskedYet), so the Pages write is unverified.
2. Voice: root cause = SFSpeechRecognizer error kLSRErrorDomain 201 "Siri and Dictation are disabled". Switched to macOS 26 SpeechAnalyzer/SpeechTranscriber (Port/Analyzer.swift), which works with Dictation off; app reserves en_US speech assets. Test: `say` through the speakers into the mic → "Please open my calendar for tomorrow morning." Yellow note now clears after 6 s / next mic press / send / new chat. Log: ~/Library/Logs/ModelPickerSpeech.log.
3. Delete all chats: sidebar button under the chat list, confirm "Delete all N chats? They go to the Trash.", moves each chat file to the Trash. Tested on a copy with --chats-dir (3 → 0); real chats untouched.
4. Duplicates: trashed ~/Projects/model-picker-backup-20261021/ModelPicker-installed.app and ~/Projects/model-picker-backup-20261021b/ModelPicker-installed.app. Spotlight now finds only ~/Applications/Model Picker.app.
5. Menu bar: icon existed but sat behind the notch (x=811). Now has autosaveName ModelPickerStatus with preferred position near the clock (x=1123, visible). Side effect: Ask My Mac's icon is now the one hidden behind the notch.
