# Sample visual assets

Original images generated with the built-in image generation tool on 24 October 2026 for this sample-data frontend. These are fictional inspiration photographs, not verified merchant/product photographs. No external source photographs were used. All four images were visually inspected for subject, composition and absence of UI or typography.

## Generation prompts

### reading-corner

Asset: `Examples/CommonThreadApp/Assets.xcassets/reading-corner.imageset/reading-corner.png`

Prompt: Use case: photorealistic-natural. Create one original portrait 2:3 editorial interior photograph for a premium home inspiration app. A tiny cozy reading nook in a small city apartment: comfortable cream upholstered reading chair, warm walnut side table, one leafy green plant, warm off-white walls, soft natural afternoon window light. Restrained lived-in warmth, authentic texture and gentle film grain, tasteful high-end shelter magazine photography, realistic scale, inviting composition. No people, no typography, no logos, no watermark, no UI, no screenshot, no collage.

### sculptural-lamp

Asset: `Examples/CommonThreadApp/Assets.xcassets/sculptural-lamp.imageset/sculptural-lamp.png`

Prompt: Use case: photorealistic-natural. Create one original portrait 2:3 editorial home detail photograph for a premium inspiration app. A sculptural cream mushroom-shaped table lamp on a beautiful walnut console beside a warm off-white textured wall. The lamp has a broad softly rounded dome and narrow matching base, warm soft light, restrained styling and tactile surfaces. Close medium composition, sophisticated yet attainable apartment detail, editorial magazine photography, subtle film grain, natural shadows. No people, no typography, no logos, no watermark, no UI, no screenshot, no collage.

### balcony

Asset: `Examples/CommonThreadApp/Assets.xcassets/balcony.imageset/balcony.png`

Prompt: Use case: photorealistic-natural. Create one original portrait 2:3 editorial interior-exterior photograph for a premium home inspiration app. A tiny city apartment balcony arranged for a quiet morning coffee ritual, two compact tasteful chairs and a small round table with two simple ceramic cups, a few green plants, soft city buildings beyond the railing. Warm inviting natural morning light, realistic compact proportions, authentic textures, restrained cream and warm wood tones, tasteful editorial magazine photography. No people, no typography, no logos, no watermark, no UI, no screenshot, no collage.

### ceramics

Asset: `Examples/CommonThreadApp/Assets.xcassets/ceramics.imageset/ceramics.png`

Prompt: Use case: photorealistic-natural. Create one original portrait 2:3 editorial home detail photograph for a premium home inspiration app. A small collection of earthy sculptural ceramic vases and bowls arranged on a walnut shelf against a warm cream plaster wall. Organic minimal shapes, a few beautifully imperfect handmade surfaces, terracotta, sand, warm cream and muted brown. Soft side window light and nuanced shadows, tactile high-end editorial photography, restrained composition and subtle film grain. No people, no typography, no logos, no watermark, no UI, no screenshot, no collage.

## Mynah Finds branding

The app icon and Javan mynah mascot reuse the team's existing platform-icons-v2 artwork from the [branding branch](https://github.com/Haydnlee31/AIGrandPrixT12/tree/838cab2fb229d6cecb8d1e19ef22d71a9ee53c04/assets/branding/platform-icons-v2). No new image generation was used for this integration; the original prompts and export instructions live with that source artwork.

- `Examples/CommonThreadApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is the unchanged opaque 1024px iOS icon (`ios/AppIcon.appiconset/AppIcon-1024.png`): the mynah with its yellow price tag on blue. The existing universal iOS icon catalog supplies the app icon.
- `Examples/CommonThreadApp/Assets.xcassets/MynahMascot.imageset/MynahMascot.png` is the unchanged transparent bird (`masters/chrome-transparent.png`). `FindsMark` uses it for onboarding, the Profile header and the empty library. Its ivory edge keeps the dark feathers visible in dark mode.

The obsolete bookmark icon generator was removed so it cannot overwrite the supplied branding. Ordinary bookmark symbols still indicate saved items; they are not the mascot.
