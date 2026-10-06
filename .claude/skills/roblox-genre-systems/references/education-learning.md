# Playbook: Education and learning experiences

Kind: genre
Covers: Education > (none)
Also: Party & Casual > Quiz; Puzzle > Word

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no subject, curriculum, audience, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Lessons**: short units with an explanation, an interactive activity and a check.
- **Practice**: exercises with immediate feedback, retries and hints.
- **Assessment**: quizzes or tasks that record mastery per topic.
- **Progress**: topics unlocked in order, mastery shown, review of weak topics.
- **Group mode** (optional): a teacher or host runs a session for a group, sees progress, controls pacing.
- **Exploration**: simulations or models the learner can manipulate.

## Kit modules
- `GameKit/Objectives`: lesson and topic goals, mastery records.
- `GameKit/Onboarding`: first-session guidance and step funnels.
- `GameKit/Dialogue` (dialogue/1), `UIKit/Components/DialogueBox`: guided explanations and branching feedback.
- `GameKit/Fsm`: lesson flow (intro, activity, check, result) with serialisable state.
- `GameKit/Interact`, `GameKit/Zones`: interactive stations and lesson areas.
- `GameKit/RoundLoop`, `GameKit/VotingRound`: host-run group sessions and polls.
- `GameKit/PlayerData`: saved progress and mastery.
- `GameKit/TextFilter`, `GameKit/TextFilterRoblox` (T4): any typed answer that others see.
- `UIKit/Localize`, `UIKit/Audit`: localisation and readability checks (text size, contrast, touch targets as conventions).
- `UIKit/Components/ProgressBar`, `UIKit/Components/Modal`, `UIKit/Components/Tooltip`: progress, explanations, hints.
- `Cinematics/Cinematics`: guided camera tours of models.

## Data to author
- Topic graph: lessons, prerequisites, activities, checks (TBD).
- Question and exercise bank with answers and feedback text (TBD).
- Mastery rule: what counts as passing a topic (TBD).
- Host controls for group mode (TBD).
- Localisation keys for every learner-facing string (TBD).

## Authority and abuse risks
- **Answer leaks**: answers stay on the server until the learner submits.
- **Progress tampering**: mastery is recorded from server-checked answers only.
- **Group sessions**: only the host can change pacing; join codes are rate-limited.
- **Typed answers shown to others**: filtered before display.

## Performance pitfalls
- Heavy interactive models: budget parts and effects per station; test on low-end devices common in classrooms (TBD device list).
- Large text in many panels: virtualise long lists, avoid rebuilding UI per frame.
- Network in classrooms can be constrained: keep payloads small and tolerate delays.

## Policy notes
- The audience decides the maturity label and Kids and Select eligibility: Kids (ages 5-8) needs a Minimal or Mild label and Select (9-15) also allows Moderate (release research, section 1a).
- Requests for personal information are not allowed (Community Standards); progress uses Roblox identities only.
- AI-generated feedback, if used, is an "AI interactions" questionnaire item and its text must be filtered.

## Test checklist
- [ ] Topic graph validates: no cycles, every lesson reachable.
- [ ] Every exercise has a correct answer and feedback; wrong-answer paths lead back to practice.
- [ ] Mastery changes only from server-checked submissions.
- [ ] Every learner-facing string has a localisation key; pseudo-localised text fits its frame (`UIKit/Audit`).
- [ ] Text sizes and touch targets pass the audit conventions on phone and tablet profiles.
- [ ] Group mode: host controls apply to every member; a member cannot advance the group.

## Design questions (TBD)
- TBD: Which subject and which age range?
- TBD: Self-paced, host-led, or both?
- TBD: How is mastery measured and shown?
- TBD: Which languages at launch?
- TBD: Is progress shared with anyone besides the learner?

## Reference systems
- Kids and Select audience rules and the maturity questionnaire in the [release research](../../../../docs/research/release-monetization-analytics-2026-10.md), section 1.
- UIKit audit conventions in [runtime-kits.md](../../../../docs/runtime-kits.md), section 2; skill `roblox-ui-ux-pass`.
- Systems X06, X07 and X25 in the [genre coverage research](../../../../docs/research/genre-coverage-2026-10.md).
