# Switchboard

Switchboard is a Mac app for chatting with AI models that run **on your own computer**. Nothing goes to the cloud. You pick a model, or let **Auto** pick one, and talk to it in one simple chat window. (Switchboard used to be called Model Picker.)

## What it does

- **One chat, many models.** It shows every local model in one list, grouped by the app that runs it (Osaurus, Ollama, LM Studio, or Switchboard's own small servers). You can collapse each group except Auto.
- **Auto.** It picks the best model for the chat once and keeps it for the whole chat. Pictures go to a model that can see.
- **Pictures and files.** You can paste a picture (Cmd+V), drag files in, or click 📎. PDFs, Word files and text files are read all the way to the end, never cut off.
- **Vision.** LFM3-VL 2B is the first picture reader (Auto, the camera button and the paperclip), then Bonsai 2 4B, Bonsai 2 9B, Gemma 4 and any other picture model. If LFM3-VL won't start or errors, Bonsai takes over. Photo Reader (port 8093) is only the last resort, for when nothing else can see.
- **Saves memory while idle.** Switchboard's own model servers (LFM3, Bonsai, Spark, Apple) stop by themselves after 15 minutes with no messages and start again on the next one. Osaurus, Ollama, LM Studio, Magnitude and other apps are never stopped by this.
- **Hands on your Mac.** Tool-capable models can find, open, copy, move, rename and trash files, and create or edit documents. Anything that changes a file asks for your Approve first, and Undo reverses the last action.
- **Playable results.** When a chat builds a game or web page, it's saved as a real file and gets a green ▶ Play button.
- **Saves memory.** An engine app (Osaurus, Ollama, LM Studio) opens only when the chosen model needs it, at most once. When you quit Switchboard, and Ask My Mac isn't open, the models it started shut down. Closing the window keeps it in the menu bar; Quit stops the models.
- **Delete all chats** clears your history in one click.

## The models

| Model | Runs on | Sees pictures |
|---|---|---|
| LFM3-VL 2B (Liquid AI, Auto's first picture reader) | Switchboard server (own llama.cpp copy, `~/Models/lfm3/start.sh vl`), port 8111 | Yes |
| LFM3 1.7B (Liquid AI, long documents, manual pick) | Switchboard server (`~/Models/lfm3/start.sh text`), port 8110 | No |
| Bonsai 2 4B (Auto's usual quick-chat pick, picture backup) | Switchboard server, port 8097 | Yes |
| Bonsai 2 9B | Switchboard server, port 8098 | Yes |
| Spark | Switchboard server, port 8095 | No |
| Raptor 0.6 4B, Bonsai 2 27B | Osaurus (port 1337) | No |
| gemma4:e2b, gemma2:2b, ornith, qwen2.5-coder | Ollama (port 11434) | gemma4:e2b only |
| Apple (built-in), `apple-builtin` | Apple Brain helper, port 8100 ([apple-brain](https://github.com/madhatter2727/apple-brain)). Started only when you or Auto pick it, stopped when Switchboard quits. Auto uses it only for plain, short chat: no attachments, files, app control, coding or long reasoning, and the chat plus reply under ~2,500 tokens. If it won't start or errors, Auto falls back once to its usual pick. Chat only. | No |

## How it fits together

- `mac/` is the Swift Mac app: window, menu-bar icon, quick-chat popover and settings.
- `web/` is the chat screen itself (`app.js`, `index.html`, `style.css`).
- A small helper runs in the background on `127.0.0.1:7777` (LaunchAgent `com.tara.modelpicker.proxy`). It routes each message to the right model, and other apps, like Ask My Mac, can use it too. Model `auto` there uses Auto's rules (pictures, coding, files and tools, quick chat), but never Apple (built-in). Try `Switchboard --route-auto 'BODY_JSON'` to see the pick without sending anything.
- Chats and settings live in `~/Library/Application Support/Model Picker/`. The folder keeps its old name so nothing was lost in the rename.
- `bench/` and `test-sandbox/` hold speed tests and test scripts. `examples/` holds a sample game.

## Install or update

```bash
cd mac && ./install-app.sh
open -n "$HOME/Applications/Switchboard.app"
```

This needs the Swift command-line tools. Model files aren't stored in this repo; they live in `~/Models` and in each engine app.

## Privacy

Everything runs locally. No keys, chats, photos or model files are kept in this repo.
