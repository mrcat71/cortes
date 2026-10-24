# Cortes

Inner voices for your work chats, inspired by Disco Elysium's skill system. Cortes is a macOS menu bar app
that reads the Slack conversation you're looking at and shows a floating "inner parliament": Logic,
Empathy, Sarcasm and Paranoia read the situation, disagree, and each suggests a reply you can copy.
It never sends anything.

**Status: step 2.** The voices default to local Gemma 4 12B through [Ollama](https://ollama.com); z.ai's cloud
(GLM) stays available as an alternative engine. There's no audio yet.

## Requirements

- macOS 15 or later on Apple Silicon (built with Xcode 27, Swift 6.4).
- Slack's desktop app.
- For the local engine: [Ollama](https://ollama.com) running and `ollama pull gemma4:12b` done once (about
  8 GB of disk and 8-10 GB of RAM while in use).
- For the cloud engine: a z.ai API key.

## Build and run

```sh
make signing-identity   # once per Mac: a self-signed "Cortes Local Signing" certificate in your login keychain
make run                # build, sign, (re)launch
make demo               # same, with the Demo Chat window open
make test               # unit tests
```

The app lands in `build/DerivedData/Build/Products/Debug/Cortes.app`. Without the local identity, builds
are ad-hoc signed and macOS ties the Accessibility grant to that exact build, so every rebuild silently
loses it. With the identity, the grant survives rebuilds. Remove the identity with
`security delete-identity -c "Cortes Local Signing"`. Building from Xcode (⌘R) stays ad-hoc signed.

## First run

1. **Accessibility.** Menu bar icon → *Grant Accessibility…*, then enable Cortes in System Settings →
   Privacy & Security → Accessibility. If the icon still shows ⚠ although Cortes is enabled there, the
   entry belongs to an older build: run `tccutil reset Accessibility io.github.mrcat71.cortes` and grant
   again.
2. **Model.** *Settings… → Model*: the default engine is *Local (Ollama)* - check the URL and model, then
   *Check Ollama* (it tells you when the model isn't downloaded yet). Switch to *z.ai cloud* only if you
   want GLM: then paste the key, *Save to Keychain*, and *Test connection*. The key is stored only in
   Keychain (`ZAI_API_KEY` in the environment overrides it). A GLM Coding Plan key works only on the
   Coding Plan endpoint, and z.ai's terms limit that plan to supported coding tools.
3. **Allow a conversation.** Open a Slack conversation, then menu bar icon → *Allow analysis*. Nothing is
   ever analyzed for conversations that aren't on this list, local or cloud.
4. Press **⌃⌥V** in Slack. Press it again to dismiss. (⌃⌥Space is the default input-source shortcut,
   so Cortes doesn't use it.)

## How it works

- **Capture:** the Accessibility tree of the focused Slack window, read about once a second while Slack is
  frontmost. Cortes sets Electron's `AXManualAccessibility` flag (never `AXEnhancedUserInterface`), finds
  the message list in `.p-message_pane`, and reads each message's sender, time and text. Details:
  [docs/poc-results.md](docs/poc-results.md).
- **Modes:** *Manual* (hotkey only), *Auto* (fires when a new message from someone else scores high
  enough: DM or @mention, a question, tension words; 1.5 s debounce, dedup, cooldowns) and *Paused*.
  Auto sensitivity *Every message* drops the score gate and the cooldowns entirely: every incoming
  message gets fresh takes, which is cheap on the local engine.
- **Generation:** the local engine goes through Ollama's `/api/chat` with thinking off
  and the output grammar-constrained by a JSON schema built from the enabled voices (each voice may only
  pick its own strategies, scores stay 0-9). If Ollama returns HTTP 501 with `structured output is unavailable`
  (for example, a build missing the grammar library), Cortes retries without the `format` parameter,
  using the same local model and JSON prompt. The cloud engine uses Chat Completions with JSON mode; a
  validator still checks both paths and asks for one repair.
- **Decision:** deterministic rules raise risk (humor under tension, insults, blame, strong promises,
  shouting, @channel, links or contact details). The safest useful reply gets ★; risky ones stay
  visible with ⚠ and the reason, so you can still pick them.
- **Overlay:** a non-activating floating panel. *Copy* never steals focus from Slack, so ⌘V works
  right away.

## Privacy

- On the local engine nothing ever leaves the Mac; the allowlist then simply decides which conversations
  Cortes reads. On the cloud engine, only allowlisted conversations leave the Mac (the Demo Chat is
  synthetic and always allowed).
- Before prompting, participant names become aliases and emails, links and phone numbers become
  placeholders (*Settings → Privacy*). Names are restored locally in the suggestions.
- Conversation state stays in memory and is wiped on pause, sleep and screen lock. Nothing is written
  to disk except settings and the Keychain item.
- Chat text is treated as untrusted data: invisible and bidi characters are stripped, special-token
  look-alikes are defanged, and output renders as plain text.

## Demo without Slack

Menu bar icon → *Demo Chat…* replays a scripted conversation: *Next message* adds the next line,
and *Ask the voices* (or ⌃⌥V while the window is focused) asks the voices. *Settings → Model → Replay*
answers with a canned result and no network, as a last-resort demo fallback.

## Developer CLI and tests

```sh
cd Packages/CortesKit
swift test                                    # unit tests, no network
swift run cortes-cli slack                    # read the focused Slack conversation (text masked; --raw to show it)
swift run cortes-cli prompt launch-war-room   # print the prompts for a scenario
OLLAMA_MODEL=gemma4:12b swift run cortes-cli ask launch-war-room 5   # local voices
ZAI_API_KEY=... ZAI_BASE_URL=https://api.z.ai/api/coding/paas/v4 swift run cortes-cli ask launch-war-room 5
```

`cortes-cli slack` uses the terminal's Accessibility permission. `ask` picks its backend from the
environment: `ZAI_API_KEY` → z.ai, `OLLAMA_URL`/`OLLAMA_MODEL` → Ollama, otherwise the replay backend.

## Adding a voice

A voice is one JSON file: copy one from `Packages/CortesKit/Sources/CortesKit/Resources/Voices/` and
give it a new `id`, a worldview, and strategies no other voice uses (overlaps are rejected, so voices
genuinely disagree). Personal voices can also live in `~/Library/Application Support/Cortes/Voices/`.

## Layout

```text
App/                    menu bar app: AppModel, overlay panel, settings, Demo Chat
Packages/CortesKit/     logic: Slack capture, prompts, Ollama + z.ai backends, validation, decisions, voices, scenarios
docs/                   proof-of-concept results
```

Disco Elysium is a trademark of ZA/UM. Cortes is an unaffiliated fan-inspired project and uses no art or
text from the game.
