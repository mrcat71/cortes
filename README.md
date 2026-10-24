# Cortes

Inner voices for your work chats, inspired by Disco Elysium's skill system. Cortes is a macOS menu bar app
that reads the Slack conversation you're looking at and shows a floating "inner parliament": Logic,
Empathy, Sarcasm and Paranoia read the situation, disagree, and each suggests a reply you can copy.
It never sends anything.

**Status: step 1.** The voices run on GLM through z.ai's API (cloud). Local Gemma 4 12B comes in step 2.
There's no audio yet.

## Requirements

- macOS 15 or later on Apple Silicon (built with Xcode 27, Swift 6.4).
- Slack's desktop app.
- A z.ai API key.

## Build and run

```sh
xcodebuild -project Cortes.xcodeproj -scheme Cortes -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Cortes.app
```

Or open `Cortes.xcodeproj` in Xcode and run the `Cortes` scheme. Add `--args --demo` to the `open`
command to start with the Demo Chat window open.

## First run

1. **Accessibility.** Menu bar icon → *Grant Accessibility…*, then enable Cortes in System Settings →
   Privacy & Security → Accessibility. Builds are ad-hoc signed, so every rebuild needs this again:
   remove the old Cortes entry with − and add the new build.
2. **z.ai key.** *Settings… → Model*: pick the endpoint, paste the key, *Save to Keychain*, then *Test
   connection*. The key is stored only in Keychain (`ZAI_API_KEY` in the environment overrides it).
   A GLM Coding Plan key works only on the Coding Plan endpoint, and z.ai's terms limit that plan to
   supported coding tools.
3. **Allow a conversation.** Open a Slack conversation, then menu bar icon → *Allow cloud analysis*.
   Nothing is ever sent for conversations that aren't on this list.
4. Press **⌃⌥V** in Slack. Press it again to dismiss. (⌃⌥Space is the default input-source shortcut,
   so Cortes doesn't use it.)

## How it works

- **Capture:** the Accessibility tree of the focused Slack window, read about once a second while Slack is
  frontmost. Cortes sets Electron's `AXManualAccessibility` flag (never `AXEnhancedUserInterface`), finds
  the message list in `.p-message_pane`, and reads each message's sender, time and text. Details:
  [docs/poc-results.md](docs/poc-results.md).
- **Modes:** *Manual* (hotkey only), *Auto* (fires when a new message from someone else scores high
  enough: DM or @mention, a question, tension words; 1.5 s debounce, dedup, cooldowns) and *Paused*.
- **Generation:** one Chat Completions call with JSON mode and thinking disabled. If the model rejects
  either option, Cortes retries without it. A validator checks the output and asks for one repair.
- **Decision:** deterministic rules raise risk (humor under tension, insults, blame, strong promises,
  shouting, @channel, links or contact details). The safest useful reply gets ★; risky ones stay
  visible with ⚠ and the reason, so you can still pick them.
- **Overlay:** a non-activating floating panel. *Copy* never steals focus from Slack, so ⌘V works
  right away.

## Privacy

- Only allowlisted conversations leave the Mac. The Demo Chat is synthetic and always allowed.
- Before sending, participant names become aliases and emails, links and phone numbers become
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
ZAI_API_KEY=... ZAI_BASE_URL=https://api.z.ai/api/coding/paas/v4 swift run cortes-cli ask launch-war-room 5
```

`cortes-cli slack` uses the terminal's Accessibility permission. `ask` falls back to the replay backend
when `ZAI_API_KEY` is unset.

## Adding a voice

A voice is one JSON file: copy one from `Packages/CortesKit/Sources/CortesKit/Resources/Voices/` and
give it a new `id`, a worldview, and strategies no other voice uses (overlaps are rejected, so voices
genuinely disagree). Personal voices can also live in `~/Library/Application Support/Cortes/Voices/`.

## Layout

```text
App/                    menu bar app: AppModel, overlay panel, settings, Demo Chat
Packages/CortesKit/     logic: Slack capture, prompts, z.ai backend, validation, decisions, voices, scenarios
docs/                   proof-of-concept results
```

Disco Elysium is a trademark of ZA/UM. Cortes is an unaffiliated fan-inspired project and uses no art or
text from the game.
