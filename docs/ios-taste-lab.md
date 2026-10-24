# Taste Lab

A prepared reading-corner scenario in Explore, using three illustrative AI images: original warm room, same furniture under cooler diffuse light, and a wooden-chair variant under the original warm light. The images were visually inspected for retained composition; these are not pixel-identical scientific controls or purchasable scenes.

Two comparisons accept A, B, Both, or Neither, with Undo. The session records the dimension and choice. Lighting preference without a chair preference tentatively redirects the initial furniture hypothesis toward lamps. Choosing both dimensions acknowledges both. Ambiguous answers do not pre-fill a preference. Users confirm Lighting/Furniture and edit the brief before retrieving real catalog products with images and exact source links. This prepared scenario supports lamp/chair briefs. Unsuitable child, office, dining, outdoor and renewed listings are excluded from the reading-corner results. No claim about a lamp's color temperature is made unless supported by its listing.

The interpretation is deterministic and tentative, not a hidden psychological model. Choices are in view state, not saved to a user profile or library. Recommendation results use the existing brief cache and read-only relay. A new sheet starts a new session.

Validation: signed Xcode build; physical iPhone installation. Launch was blocked while the device required its passcode. Swift tests cover all 16 response combinations, undo, ambiguous answers, new-session isolation, product-family extraction and unsuitable title rejection. Live relay calls returned lamp listings for the lighting brief and chair listings for the furniture brief. Physical A/B interaction remains a user acceptance check.

## Dia extension demo

Downloaded a snapshot of origin/haydn_backend_v1 to /Users/adityaarya/Developer/Mynah-Dia-Extension. Installed experiments/chrome-sidepanel (Mynah Finds 0.4.0), not the older extension popup scaffold. Dia showed Extension loaded and On, extension enabled, ID dpfdbmboogdhnhnnglfibanlmhhbfhok. All 32 side-panel tests passed. Backend connection is not configured; iOS remains local. This is not proof of cross-device library synchronization. Browser control became unreliable during the follow-up open/pin attempt; pinning and live capture were not confirmed.

## Dynamic catalog experiments

Taste Lab now defaults to AI-curated comparisons from the enabled catalog, using actual saved-interest context where available. The planner selects verified distinct products from the same catalog category and returns an activity, question, comparison dimension, short labels and optional saved-source attribution. Product IDs, categories, duplicate pairs and source IDs are validated before responding. Actual catalog photos and exact merchant links are retained; no generated illustration is presented as a real listing. Real product comparisons are explicitly not controlled single-variable experiments. The prepared reading-corner experiment remains a separate, labeled option.

The new UI shows two photos side by side, selection borders/checkmarks, Look closer, Both, Neither and Undo. Session choices are retained per case until new cases are requested or the sheet closes. Interpretation uses a live model request, remains tentative, and leaves Both/Neither briefs blank unless the user clarifies. Explicit corrections preserve the user's wording and override a conflicting model category when a single named product type is identifiable. The edited brief drives fresh catalog recommendations without saving a permanent preference.

Library saved-product Details and Saved text are expanded inline rather than collapsed. Source summaries, evidence and uncertainties remain readable on the product page.

Validation: dynamic cold-start live planner returned four cases in 11.2 seconds (watch, lamp, packing cubes and seating). Neither returned an empty brief. Full backend suite passed 762 tests before two final interpretation regression tests; the final focused taste suite passed 11 tests. Signed iOS build and installation succeeded. No fresh on-device comparison acceptance is claimed yet.

The live explicit correction test changed a watch comparison to a warm reading lamp and returned 24 lamp matches. Final focused suite: 11 passing tests. On-device visual inspection confirmed the dynamic case list and real product thumbnails render. Gesture selection and final recommendation navigation still need physical acceptance.
