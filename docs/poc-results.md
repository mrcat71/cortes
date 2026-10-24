# Proof-of-concept results

## E1: reading Slack through Accessibility (2026-10-24): go

Setup: Slack 4.51.180 (Electron 43.1.1) on macOS 27.0.1, MacBook Pro M4. Accessibility was granted to the
terminal host, and every probe masked message text, so no conversation content was read.

Findings:

- Without help, Slack's tree has 12 nodes (only the native window frame). After
  `AXManualAccessibility = true` on the application element (result `0`), the web content appears in
  under 2 s: about 650-930 nodes with Chromium's `AXDOMClassList` and `AXDOMIdentifier`. Reading the flag
  back returns `false`, but the tree stays populated.
- Message list: `.p-message_pane` → `AXList` (subrole `AXContentList`, description = conversation name).
  Each row is a `.c-virtual_list__item` with DOM id `message-list_<ts>`, where `<ts>` is Slack's message
  timestamp (`1792673677.999169`), a stable key. Day dividers use 13-digit ids (`…000.D…`, `…divider`) and
  are skipped.
- Per message (`.c-message_kit__actions`):
  - sender: `.c-message__sender_button` (`AXTitle`); missing on grouped follow-ups, so the previous
    author is carried forward;
  - time: `.c-timestamp` link, whose first static text is the label (`14:54`) and whose description has
    the full date;
  - text: `.p-rich_text_section`, `.c-mrkdwn__pre` (code), `.c-mrkdwn__quote` (quotes, with inline
    `.c-mrkdwn__code`);
  - emoji: inline `AXImage` with a name description;
  - reactions: `.c-message_kit__reaction_bar` (skipped).
- Your own name: the first static text in `.p-channel_sidebar__channel--im-you`. Conversation name:
  `.p-view_header__big_button`, which also carries `--dm` for direct messages.
- Geometry: the pane, window and composer (`.p-message_input_unstyled`) frames are exposed, which is
  enough to dock the overlay.
- Cost: a full read through `SlackAXReader` (window walk with the sidebar skipped, then message parsing)
  took 95 ms for 13 messages. No typing lag was observed during the probes; the full 300-character typing
  test from the plan hasn't been run yet.

Known gaps: the first visible message of a group has no sender ("Unknown"). Very long code or log blocks
are cut to 500 characters before prompting. Threads in the side panel aren't read yet.

## E2z: z.ai latency and JSON reliability: pending

Needs a key in *Settings → Model*. `cortes-cli ask <scenario>` with `ZAI_API_KEY` set prints latency, the
validator result and the verdict.

## E2o: local Ollama + Gemma 4 12B latency and JSON reliability (2026-10-26): go, with one caveat

Setup: Ollama 0.40.10, `gemma4:12b` (default quantization, 7.7 GB), MacBook Pro M4. One `/api/chat` call
per run, thinking off, `num_ctx` 8192, grammar-constrained by the per-batch JSON schema (`format`), 1200
token budget. `OLLAMA_MODEL=gemma4:12b swift run cortes-cli ask <scenario>`.

Results (3 runs, 2 scenarios):

- JSON reliability: 3/3 valid outputs on the first try, zero repairs. Strategy enums, score bounds and
  key sets are enforced by the grammar, so the validator only has to police word counts and voice presence.
- The schema's key order survives in the output: `read` first, scores after each voice's text.
- Latency: 25.3 s cold (model load) and ~26.6 s warm for a 4-voice batch on the 12B dense model. That is
  prompt eval plus ~400 generated tokens; usable for manual ⌃⌥V runs, sluggish for auto-on-every-message.
  The MoE `gemma4:26b` (4B active) or `gemma4:e4b` should generate faster if this bothers; untested here.
- Verdict quality: `launch-war-room` read as to_me=true / tension 8 / need now, recommended Logic with a
  placeholder-bearing reply, and the decision engine correctly benched Sarcasm (humor under tension).
- Caveat: on `ru-report` (a Russian chat) the gist came back in Russian but thoughts and replies drifted
  to English, violating the prompt's language rule. A 12B local model is weaker at such instruction
  detail than the cloud GLMs; an explicit "the chat's language is X" line in the situation header is the
  likely fix if it matters.

## E4: overlay behavior: partly verified

Verified through Accessibility automation with the replay backend: the panel docks next to the anchor
window, grows to fit the result (380×623 pt for four voices), and the global ⌃⌥V hotkey triggers a run.
Still to check by hand: Copy followed by ⌘V into Slack, full-screen Spaces, a second display.
