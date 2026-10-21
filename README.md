# Switchboard

Switchboard is a Mac app for chatting with AI models that run **on your own computer**. Nothing goes to the cloud. You pick a model, or let **Auto** pick one, and talk to it in one simple chat window. (Switchboard used to be called Model Picker.)

## What it does

- **One chat, many models.** It shows every local model in one list, grouped by the app that runs it (Osaurus, Ollama, LM Studio, or Switchboard's own small servers). You can collapse each group except Auto.
- **Auto.** It picks the best model for the chat once and keeps it for the whole chat. Pictures go to a model that can see.
- **Pictures and files.** You can paste a picture (Cmd+V), drag files in, or click 📎. PDFs, Word files and text files are read all the way to the end, never cut off.
- **Vision.** Bonsai 2 4B and 9B can see pictures. Models that can't see get a description from Photo Reader (a small picture model on port 8093).
- **Hands on your Mac.** Tool-capable models can find, open, copy, move, rename and trash files, and create or edit documents. Anything that changes a file asks for your Approve first, and Undo reverses the last action.
- **Playable results.** When a chat builds a game or web page, it's saved as a real file and gets a green ▶ Play button.
- **Saves memory.** An engine app (Osaurus, Ollama, LM Studio) opens only when the chosen model needs it, at most once. When you quit Switchboard, and Ask My Mac isn't open, the models it started shut down. Closing the window keeps it in the menu bar; Quit stops the models.
- **Delete all chats** clears your history in one click.

## The models

| Model | Runs on | Sees pictures |
|---|---|---|
| Bonsai 2 4B (Auto's usual pick) | Switchboard server, port 8097 | Yes |
| Bonsai 2 9B | Switchboard server, port 8098 | Yes |
| Spark | Switchboard server, port 8095 | No |
| Raptor 0.6 4B, Bonsai 2 27B | Osaurus (port 1337) | No |
| gemma4:e2b, gemma2:2b, ornith, qwen2.5-coder | Ollama (port 11434) | gemma4:e2b only |

## How it fits together

- `mac/` is the Swift Mac app: window, menu-bar icon, quick-chat popover and settings.
- `web/` is the chat screen itself (`app.js`, `index.html`, `style.css`).
- A small helper runs in the background on `127.0.0.1:7777` (LaunchAgent `com.tara.modelpicker.proxy`). It routes each message to the right model, and other apps, like Ask My Mac, can use it too.
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
