# Coupang: social inspiration to products — feasibility

Checked: 24 October 2026, Singapore. This assesses an external app that turns social inspiration into products or an activity plan. It does not implement the app.

## Conclusion

**A user-selected inspiration flow is feasible; passive, universal access to Instagram, TikTok, and YouTube viewing history is not a sound default assumption.** History access, content analysis, and product matching are three separate integration problems. User consent alone does not create platform API access.

## What can be imported

| Platform | Official route | Important limit |
|---|---|---|
| Instagram | Instagram APIs support professional accounts managing their presence. | Do not promise a consumer's complete watched, saved, or liked feed. The documented professional-account features do not establish that capability. |
| TikTok | Display API exposes an authorised creator's uploaded videos. Data Portability API separately exposes approved categories of account data. | Uploaded videos are not watch history. Portability is subject to approval and covers EEA/UK users; activity records do not themselves provide raw video files. |
| YouTube | Data API can retrieve an authorised user's liked videos. A separate Google portability route covers YouTube activity. | Data API does not retrieve watch-history or Watch Later playlists. Portability is reviewed and region-limited; Singapore is not listed in the checked eligibility page. |

Sources: Meta's own [Instagram Login collection](https://www.postman.com/meta/instagram/folder/6raa77c/instagram-api-with-instagram-login) and [Facebook Login collection](https://www.postman.com/meta/instagram/folder/u4g5a2a/instagram-api-with-facebook-login); TikTok [Display API](https://developers.tiktok.com/docs/en/display-api-overview), [portability access](https://developers.tiktok.com/products/data-portability-api/), and [data types](https://developers.tiktok.com/docs/en/data-portability-data-types); YouTube [playlist restrictions](https://developers.google.com/youtube/data/reference/rest/v3/playlistItems/list) and [liked-video filter](https://developers.google.com/youtube/v3/docs/videos/list); Google [activity schema](https://developers.google.com/data-portability/schema-reference/my_activity) and [portability availability](https://support.google.com/accounts/answer/14452558?hl=en).

A user-supplied account export is a possible separate import design, not continuous account access. Treat schema support, export contents, and refresh frequency as integration work still to test.

## Sharing a link is different from receiving media

Android apps can register as share targets and receive the sender's actual payload: text/URLs or media streams. On iOS, a Share extension receives the host app's supplied text and attachments, which may be links, images, or videos. Registering support for video does not force another app to supply video. Test each source app and operating-system version. [Android receiving shared data](https://developer.android.com/develop/ui/compose/sharing/receive), [Apple Share extensions — archived official guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html)

Therefore:

- **Shared URL:** identifies the source; it does not automatically grant downloadable video bytes, frames, captions, or history.
- **Selected screenshot or permitted image/video upload:** supplies pixels the prototype can analyse directly.
- **Native share extension:** convenient production entry, requiring native integration.
- **Web prototype:** paste a link and upload selected media; it does not need to pretend a native integration is already built.

There is an important official exception for analysis: **Gemini API documents public YouTube URLs as video-understanding inputs**, currently a preview feature. Private and unlisted videos are unsupported. This provides a documented analysis route for eligible YouTube links; equivalent coverage was not established for Instagram or TikTok. [Gemini video understanding](https://ai.google.dev/gemini-api/docs/video-understanding)

The ordinary YouTube Data API supplies metadata, not general video downloads; its caption-download method requires permission to edit the video. YouTube API policy restricts downloading or importing audiovisual content without prior written approval. Do not assume an embed or viewer OAuth provides raw media; equally, do not conflate those restrictions with the separately documented Gemini feature. [Video metadata](https://developers.google.com/youtube/data/reference/rest/v3/videos), [caption access](https://developers.google.com/youtube/data/reference/rest/v3/captions/download), [API policy](https://developers.google.com/youtube/terms/developer-policies)

## Proposed hackathon experience

Start with deliberately shared inspiration rather than an invisible history reader. Offer two explicit modes:

1. **Find this:** identify a selected item, use visible brand/model evidence where available, then search a real catalogue. Offer exact matches only when supported; otherwise label visually similar alternatives. Product-search documentation describes similarity ranking, which is not an identity guarantee. [Google Vision Product Search](https://docs.cloud.google.com/vision/product-search/docs)
2. **Help me do this:** infer the activity, ask about the user's situation and existing equipment, then produce a plan and optional missing-items basket. Clearly distinguish **seen in the content**, **inferred as necessary**, and **optional upgrades**.

Demonstrate with a small known catalogue and permitted sample media. Keep the original reference, evidence, uncertainty, budget, and editable selections visible. Validate independently whether people actually share inspiration, whether analysis identifies the relevant object/activity, and whether the resulting plan is useful. These are untested product assumptions, not outcomes guaranteed by API availability.
