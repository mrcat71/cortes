# Cortes

**Four inner voices. One work chat. You decide what to send.**

Cortes is a native macOS menu bar app for people navigating tense or ambiguous Slack conversations.
Inspired by Disco Elysium's skill system, Logic, Empathy, Sarcasm and Paranoia interpret the conversation,
disagree, and suggest different replies in a floating overlay. A deterministic decision layer recommends
a reply and explains risk flags. Sometimes the recommendation is to say nothing yet.

In **Settings → General → Perspectives**, switch between **Inner voices** (the default) and **Business**.
Business brings Developer, Product Owner, DevOps and QA perspectives to the same conversation, weighing
implementation, customer value, operational reliability and testing. The choice persists across launches
and is separate from Manual/Auto/Paused activation and Local/Cloud/Replay inference. Switching cancels
pending suggestions and dismisses the old results; ask again to hear the selected perspectives.

The default AI is **Gemma 4 12B running locally through Ollama**. No API key is needed. Cortes only
copies replies to your clipboard: it never sends messages. This walkthrough covers Demo Chat and Slack;
suggestions are displayed as text.

## Run it

### Requirements

- An Apple Silicon Mac with macOS 15 or later. The development setup uses Xcode 27 and Swift 6.4;
  the package declares Swift tools 6.0. Older toolchains have not been verified.
- Xcode with its command-line tools selected.
- [Ollama](https://ollama.com) running locally. Allow about 8 GB of disk for `gemma4:12b` and
  roughly 8-10 GB of model memory, in addition to macOS and other apps.
- Slack's desktop app and Accessibility permission only for the live Slack workflow.
  The built-in Demo Chat needs neither.

### First useful result, without Slack

Start the Ollama app, or run `ollama serve` in a separate terminal, then:

```sh
git clone https://github.com/mrcat71/cortes.git
cd cortes
ollama pull gemma4:12b
make demo
```

1. In Cortes' menu bar menu, open **Settings → Model**, select **Local (Ollama)**, and click
   **Check Ollama**. The defaults are `http://127.0.0.1:11434` and `gemma4:12b`.
2. In Demo Chat, click **Next message** to reveal more of the conversation.
3. Click **Ask the voices**. Compare the perspectives, the starred recommendation and the risk reasons.
   Click **Copy** on a reply you want to use; fill in any highlighted placeholders before sending it yourself.

After the initial build and model download, the demo needs no account or API key. Generation is not
instant: the repository's [local-model smoke-test notes](docs/poc-results.md)
record roughly 25-27 seconds for four voices on an M4 MacBook Pro, not a latency guarantee.
Local (Ollama) answers now appear one completed voice at a time while the remaining voices generate.
These are previews: Copy and the recommendation unlock only after the full answer is validated.
Streaming reduces the wait before you can start reading, not the model's total generation time.
Cloud and Replay still display the complete answer at once. Invalid output clears the previews before
one repair attempt; a failed or interrupted stream never becomes a final recommendation.

For an offline UI fallback, select **Settings → Model → Replay**. It returns a fixed, canned answer,
not live model inference and not an evaluation result.

### Conversations for the live demo

Select a conversation in Demo Chat, then use **Next message** to reveal the dilemma. Each starts with
two messages; **Restart** returns to that opening. All participants and conversations are synthetic.

| Scenario in the picker | CLI ID | What to explore |
| --- | --- | --- |
| #friday-release | `friday-release` | A customer needs a checkout fix, but a retry test double-charges an order and rollback is not straightforward. Compare Business perspectives on scope, release safety and test evidence. |
| #checkout-scope | `scope-creep` | Sales has hinted at extra features before a fixed demo date. Negotiate the useful minimum without inventing an estimate or skipping regression tests. |
| Jamie | `dm-credit` | A teammate claims sole credit, then asks you to run the presentation. Compare Inner voices on recognition, boundaries and preserving the relationship. |

For a 3-5 minute hackathon walkthrough, use **Manual** activation and **Local (Ollama)** inference.
Select **Business** perspectives and **#friday-release**, reveal all seven messages, and ask for advice.
Compare the four replies and their trade-offs while completed voices appear. Switch to **Inner voices**
and ask again on the same conversation to show how the lens changes, then Copy a reply for review.
Live outputs vary; these are discussion cases, not scored model evaluations. Replay does not adapt to
these conversations: its fixed answer is about the original launch-war-room scenario, so use that
scenario if demonstrating the offline fallback.

### Use it with Slack

1. Optionally run `make signing-identity` once per Mac. This creates a self-signed
   **Cortes Local Signing** certificate in your login keychain so Accessibility grants survive rebuilds.
2. Run `make run`. The app is built at `build/DerivedData/Build/Products/Debug/Cortes.app`.
3. Open the menu bar menu's **Grant Accessibility…**, then enable Cortes in
   **System Settings → Privacy & Security → Accessibility**.
4. Open a test conversation in Slack and select **Allow analysis** in Cortes' menu.
5. Press **Control + Option + V** (`⌃⌥V`) to ask the voices. Press it again to dismiss a fresh result.
   Copy a reply, review it, and paste it into Slack yourself.

Without the signing identity, the build is ad-hoc signed and Accessibility permission can be lost after
each rebuild. Xcode's Run action also stays ad-hoc signed. If Cortes shows a permission warning despite
being enabled, `tccutil reset Accessibility io.github.mrcat71.cortes` clears its existing grant;
enable it again afterward.

## Expertise: what we built into the model's workflow

The domain is everyday workplace communication: separating facts from pressure, acknowledging tension,
avoiding reckless commitments, and deciding whether a public reply or a private follow-up is appropriate.
These are hand-authored communication heuristics, not a trained psychological assessment or a validated
professional advice system. The knowledge is explicit and inspectable rather than hidden in fine-tuning:

| Voice | What it prioritizes | Deliberate blind spot |
| --- | --- | --- |
| Logic | Facts, ownership and a concrete next step | Feelings and status |
| Empathy | Lowering tension and preserving relationships | Over-apologizing and giving away ground |
| Sarcasm | Naming absurdity and preserving self-respect | The social cost of a joke |
| Paranoia | Protecting reputation and recording commitments | Seeing threats that may not exist |

Business mode uses a separate [set of role definitions](Packages/CortesKit/Sources/CortesKit/Resources/BusinessVoices/):

| Perspective | What it prioritizes | Deliberate blind spot |
| --- | --- | --- |
| Developer | Implementable scope and maintainable changes | Engineering elegance over customer value |
| Product Owner | Customer outcomes, priorities and acceptance criteria | Technical debt and operational effort |
| DevOps | Safe releases, observability and recovery | Overweighting worst-case failures |
| QA | Reproducible failures and regression evidence | Chasing unlikely edge cases |

These are simulated perspectives, not other participants or independent agents. Replies are still
written for you to send as yourself. Both modes share validation, risk checks, streaming and consent controls.
Replay uses a fixed answer matching the selected mode, not live role analysis.

- [Voice definitions](Packages/CortesKit/Sources/CortesKit/Resources/Voices/) contain the worldviews,
  goals, blind spots, example thoughts and distinct strategy lists. Overlapping strategy lists are rejected.
- [PromptBuilder.swift](Packages/CortesKit/Sources/CortesKit/PromptBuilder.swift) distinguishes your
  messages from other people's, focuses on the latest message from someone else, and asks for placeholders
  instead of invented facts. All four perspectives are generated in one batch, not four independent agents.
- [DecisionEngine.swift](Packages/CortesKit/Sources/CortesKit/DecisionEngine.swift) adds rule-based risk
  penalties for humor under tension, insults, blame, strong promises, shouting and channel-wide pings.
  Links, contact details and credential-like strings impose a risk floor. The rules can only raise risk.
- [SchemaBuilder.swift](Packages/CortesKit/Sources/CortesKit/SchemaBuilder.swift) and
  [ResponseParser.swift](Packages/CortesKit/Sources/CortesKit/ResponseParser.swift) constrain and validate
  the output. Each voice must use its own strategies; scores are bounded to 0-9.

To add a voice, copy a bundled JSON file and give it a unique `id` and non-overlapping strategies.
Personal overrides can live in `~/Library/Application Support/Cortes/Voices/`; a matching `id` replaces
the bundled definition. Business overrides belong in its `Business/` subdirectory, so each mode's
voices stay separate. Restart the app or switch perspective modes to load changes.

For a synthetic business-mode prompt or pipeline check, append `--business` to the CLI's `prompt` or
`ask` command, for example `swift run --package-path Packages/CortesKit cortes-cli prompt launch-war-room --business`.

## Model, integration and licenses

- **Default model:** Google's open-weight **Gemma 4 12B**, Ollama tag
  [`gemma4:12b`](https://ollama.com/library/gemma4:12b). Google lists Gemma 4 under
  [Apache-2.0 in its model card](https://ai.google.dev/gemma/docs/core/model_card_4).
  Model weights are downloaded separately, not bundled in this repository.
- **Inference code:** [OllamaBackend.swift](Packages/CortesKit/Sources/CortesKit/OllamaBackend.swift)
  calls `/api/chat`, with thinking disabled and an 8192-token context. It requests schema-constrained JSON.
  The app consumes streamed chunks and reveals only complete voice objects, with aliases restored locally.
  If the server reports structured output unavailable with HTTP 501, it retries without the schema.
  Both paths still run output validation and at most one repair attempt in
  [SuggestionEngine.swift](Packages/CortesKit/Sources/CortesKit/SuggestionEngine.swift).
- **Optional cloud alternative:** [Backend.swift](Packages/CortesKit/Sources/CortesKit/Backend.swift)
  implements z.ai Chat Completions, with `glm-5.2` as the default cloud model. Hosted use is subject to
  [z.ai's terms, including its API terms](https://chat.z.ai/legal-agreement/terms-of-service).
  It is not needed for the local demo. In **Settings → Model**, choose **z.ai cloud**, save a compatible
  API key to Keychain, and test the connection. `ZAI_API_KEY` in the app's environment overrides Keychain.
  A Coding Plan key is not interchangeable with a general API key; check your plan's permitted uses.
- **Cortes source code:** [Apache-2.0](LICENSE). The app uses Apple's frameworks and has no external
  Swift package dependencies in [Package.swift](Packages/CortesKit/Package.swift).

## What the extra layer demonstrably adds

The reproducible evidence today is a deterministic regression check, **not a measured win over plain
Gemma**. In the [replay fixture](Packages/CortesKit/Sources/CortesKit/Scenarios.swift), the generated
situation has tension 7 in a professional chat. Sarcasm proposes humor with model-assigned risk 6.
Cortes raises that risk to 8 for humor under tension, above the professional risk cap of 4, and excludes
it from recommendation while leaving it visible with a reason.

The test `parsesCannedOutputAndKeepsRiskyHumorVisibleButNotRecommended` verifies that the risky humor is
not recommended and that another reply is selected. Other tests cover prompt focus, redaction, schema
construction, invalid output, and Ollama's schema fallback and repair behavior:

```sh
make test
```

The `DemoTests` suite checks that all six conversations load, have distinct IDs and conversation keys,
and retain unrevealed messages. It also checks speaker attribution and prompt focus at each reveal.

The [proof-of-concept notes](docs/poc-results.md) record Slack capture, local-model latency and output
reliability checks. They do **not** establish better communication outcomes than the same model alone.
Replay results and mocked API tests must not be presented as live-model quality measurements.

**Still needed for the judges' comparison:** run the same synthetic conversations through plain
`gemma4:12b` and Cortes, keeping the model and generation settings fixed. Record both prompts and outputs,
latency, and a human-scored rubric for factual grounding, distinct actionable options, and safe handling
of tension. Publish the per-case scores and failures before claiming an improvement. No paired
plain-model benchmark has been recorded in this repository yet.

## Privacy and safety

- **Capture is separate from consent to analyze.** In the Slack workflow, Cortes polls the focused window's
  Accessibility tree about once a second. The allowlist gates model requests, not this initial local
  capture. Choose **Paused** to stop capture and clear Cortes' in-memory conversation state.
- With the default loopback Ollama URL, model requests stay on this Mac. Changing the URL to a remote
  server sends chat context there. Cloud mode sends allowed conversations to z.ai; synthetic Demo Chat
  scenarios are always allowed.
- Before prompting, Cortes keeps a recent window of up to 20 messages within a roughly 6000-character
  budget. With the default privacy setting, known participant names become aliases and emails, links and
  phone numbers become placeholders. Names are restored locally. This is not complete anonymization:
  other identifying details can remain. Only use conversations you are authorized to process.
- Cortes keeps conversation content in memory and clears its state on pause, sleep and screen lock.
  Preferences, the allowlist and detected Slack name persist in UserDefaults; an optional cloud key is
  stored in Keychain. Copied replies go to the system clipboard. These controls do not erase clipboard,
  model-server or provider state.
- The default local path needs no secrets. There is no `.env` loader; do not commit keys or put them in
  commands, fixtures or screenshots. Use the app's Keychain flow for the optional cloud backend.
- Chat text is untrusted input. The prompt tells the model not to obey transcript instructions;
  sanitization strips invisible and bidi characters and defangs special-token look-alikes. Results render
  as text, not executable markup. These mitigations do not guarantee resistance to prompt injection.
- The app has no send, delete, payment or other action tools. You review and send every message yourself.
  Risk flags are heuristics, not a guarantee that a reply is safe or appropriate.
- API and validation failures appear in the overlay with a retry option. This is a local desktop app,
  not a hosted public demo. **Auto** mode uses debounce, deduplication and cooldowns; **Every message**
  sensitivity removes the score threshold and cooldowns, so prefer **Manual** for predictable usage.

## Where it does not work well yet

- Slack capture depends on its Electron Accessibility tree and may break when Slack changes it.
  Side-panel threads are not read, grouped messages can lack an author, and long text is truncated.
- Local 12B generation takes tens of seconds on the recorded hardware. Auto mode can lag behind a busy chat.
- In the recorded Russian scenario, Gemma sometimes answered partly in English despite the language rule.
- Tone, subtext and risk scores can be wrong. The explicit language-specific risk lists are not exhaustive;
  humor and workplace relationships are context-dependent. Review all suggestions.
- The documented model workflow uses neither ElevenLabs nor the Gemini API. Replay does not respond to new inputs.
- Full-screen Spaces, multiple displays and Copy followed by paste into Slack still need manual validation
  according to the proof-of-concept notes. Intel Macs have not been verified.

## Live demo and hackathon submission

Follow the [live-demo conversation walkthrough](#conversations-for-the-live-demo) to compare Business
and Inner voices on the same release decision. Show the voice JSON,
`DecisionEngine.swift`, and the `/api/chat` call in `OllamaBackend.swift`. For a judge's new input, use an
authorized test conversation in Slack. Disclose if you switch to the canned **Replay** fallback.

Based on the supplied Hack Day Barcelona rules, the intended track is **Best Open-Source AI Project**:
an original harness around an open-weight model. It is not an Agent Skills submission, so it does not
require `SKILL.md`. **The current Ollama integration does not meet the Best Use of Gemma 4 track's
Gemini API requirement.** There is no ElevenLabs integration or Plata conversation-labeling workflow.
Final eligibility is the organizers' decision.

Before submission:

- [ ] Check that the GitHub repository opens while logged out and contains this README and `LICENSE`.
- [ ] Run the setup and live demo on the presentation Mac; keep Replay available as a disclosed fallback.
- [ ] Record the paired plain-model comparison above if claiming better results.
- [ ] Verify no credentials or real private conversation data appear in files or Git history.
- [ ] Confirm the repository and project work meet the 11:30 start rule.
- [ ] One checked-in team member submits the repository through **OrganizerHQ → Challenges → Add Submission**
  before **16:30**, selecting only the applicable tracks. A README is not a submission.

## Developer commands and layout

```sh
make build
make test
cd Packages/CortesKit
swift run cortes-cli prompt launch-war-room 5
env -u ZAI_API_KEY OLLAMA_MODEL=gemma4:12b swift run cortes-cli ask launch-war-room 5
env -u ZAI_API_KEY -u OLLAMA_URL -u OLLAMA_MODEL swift run cortes-cli ask launch-war-room 5
```

The last two commands run live local inference and offline replay, respectively. `ask` selects z.ai
when `ZAI_API_KEY` is nonempty, otherwise Ollama when `OLLAMA_URL` or `OLLAMA_MODEL` is set, otherwise
Replay. This CLI default differs from the app's local default. It prints latency, repair status,
situation, recommendation, strategies and risk reasons, not a hidden model reasoning trace.

`swift run cortes-cli slack` reads the focused Slack conversation using the terminal's Accessibility
permission and masks text by default. `--raw` prints actual conversation content; do not use it in
public demos or shared logs.

```text
App/                    SwiftUI menu bar app, overlay, settings and Demo Chat
Packages/CortesKit/      Capture, prompts, backends, validation, risk rules, voices and tests
docs/poc-results.md      Recorded proof-of-concept checks and remaining manual checks
```

Disco Elysium is a trademark of ZA/UM. Cortes is an unaffiliated fan-inspired project and uses no art or
text from the game.
