# Coupang: why someone arrives before they want to buy

Research date: 24 October 2026 (Singapore).

## The distinction that changes the concept

A person can have no purchase history and no product in mind while still having a reason to arrive: create something, respond to a friend, or plan an activity. The product must supply that reason before asking for preferences or presenting a catalogue. This is a design hypothesis, not a demonstrated acquisition channel for a new app.

Keep three questions separate: How do they find the experience? What useful or enjoyable thing do they get immediately? How does purchase intent emerge from that activity? A clever recommendation engine answers none of those automatically.

**Acquisition cold start** means earning the first visit. **Personalisation cold start** means learning enough during that visit to help. Photos and preference questions address the second; they do not solve the first.

## What existing products actually support

**Pinterest: creation and remixing.** Its documented collage flow supports image cutouts from Pins or device uploads, editing, remixing existing collages, and publishing. Remixes credit the original creator. Users can download a collage as a video, share it on other social platforms, and include a link back. This is evidence of a workflow connecting self-expression, sharing, and exploration. Pinterest's claims of engagement and adoption are company claims; they do not prove purchase conversion or that a new standalone product would acquire users. [Pinterest product announcement, 24 September 2024](https://newsroom.pinterest.com/en-gb/news/introducing-new-ways-to-create-and-share-collages/)

**Partiful: someone invites you.** A host shares an event link; guests RSVP, receive reminders, and can contribute photos. A questionnaire can collect information such as dietary restrictions, and a date poll lets guests vote before the host selects a time. The invitation provides an immediate social task without requiring purchase intent. This documents the mechanism, not a measured viral coefficient or shopping conversion. [Why use Partiful?](https://help.partiful.com/en-us/articles/15525594-why-use-partiful), [Guest questionnaires and date polls](https://help.partiful.com/en-us/articles/15525422-can-i-poll-or-survey-my-guests)

**Apple Invites: low-friction participation.** Apple's current guide says hosts need iCloud+, while guests can access events free on the web from any device, with or without an Apple Account. Invitations, RSVPs, albums, and playlists supply value independently of shopping. The transferable principle is to let recipients participate before asking them to adopt a new platform. This does not establish that a Coupang prototype should require an Apple integration. [Apple Invites guide](https://support.apple.com/en-ca/guide/apple-invites/dev5266f8d6d/ios)

**Entertainment and decision formation.** TikTok documents shopping through videos and livestream entertainment, establishing an entry mechanism but not independent causal proof of conversion. [TikTok Shop, June 2025](https://newsroom.tiktok.com/tiktok-shop-is-where-shoppers-come-to-discover?lang=en)

Google research proposes asking novices about intended use when product attributes are hard to express. Separately, Google/The Behavioural Architects describes exploration/evaluation loops among shoppers; that study does not prove how to acquire people before shopping. [Usage-related questions](https://research.google/pubs/soliciting-user-preferences-in-conversational-recommender-systems-via-usage-related-questions/), [Purchase decision research](https://business.google.com/en-all/think/consumer-insights/navigating-purchase-behavior-and-decision-making/)

## Three entry hooks to test — our proposals

| Hook | Why arrive? | Value before shopping | How weak purchase intent could form |
|---|---|---|---|
| **Remix this room** | A creator or friend shares a room concept with a remix link. | Upload a room photo or use a sample; rearrange what is already owned; save/share a personalised scene. | After choosing a preferred result, ask what one affordable change would create it. AI grounds suggestions in actual items and constraints. |
| **Help us plan Saturday** | A friend shares a dinner, picnic, or game-night invitation. | Vote on a vibe, add constraints, coordinate attendance and things people already have. | The agreed plan exposes missing supplies. AI creates an optional shared basket, explains quantities, and removes duplicates. |
| **Make my version** | A short recipe, craft, or desk-setup post links to an interactive version. | Adapt the activity to ingredients, materials, or equipment already owned. | Only after a usable plan exists does the user see optional items that unlock a different result. Buying nothing must remain a successful outcome. |

These are proposals inspired by documented workflows, not features claimed for Pinterest, Partiful, or Apple. Screenshots, photos, reactions, short voice notes, and edits can supply context during the activity. Do not treat inferred preferences as facts; let the person correct them.

## Recommendation and falsifiable checks

Prioritise **turn inspiration into a shared plan**, initially for at-home social experiences: creator/friend link → voice, photos, or polls → a plan using already-owned items → optional missing-items basket. The friend provides a reason to arrive; the plan provides value before shopping. Aspiration remixing and hobby micro-experiences remain alternatives. None proves people will install a new app. Prototype as a shareable web experience; placement inside an existing retail app is an explicit distribution assumption.

Each input should resolve uncertainty: a photo shows available space or items, voice expresses the occasion, and a poll resolves group preferences. The decision layer chooses whether to ask, show, compare, plan, or offer a basket. It is a policy for the next useful step, not a separate input modality.

Test arrival before optimising recommendations:

1. Show the proposed post or invitation to people outside the team. Do they open it, and can they explain why?
2. Remove shopping links. Is the activity still useful enough to complete, save, share, or revisit?
3. Observe which actions reveal preferences without a separate questionnaire.
4. Ask whether the proposed purchase is a natural next step or an unwelcome interruption.
5. Check whether people return after novelty fades. Separate one-time delight from a repeat reason to use the product.

Track entry-to-start, start-to-useful-result, save/share/remix, voluntary product exploration, and successful purchase handoff separately. These are measurement suggestions; no conversion targets or outcomes have been validated.
