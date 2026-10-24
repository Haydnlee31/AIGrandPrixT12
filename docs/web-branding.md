# Mynah web palette

The web branch uses a pale sky blue app-icon background and matching UI accents.
The Vercel project avatar uses the same `frontend/assets/icon-512.png`.

| Use | Light | Dark |
| --- | --- | --- |
| Soft accent surface / icon target | `#d9eef7` | `#203b46` |
| Links, controls and focus rings | `#2b708a` | `#9dd5e9` |

Light accent text has 5.54:1 contrast against white, 5.00:1 against the neutral
surface and 4.63:1 against the soft accent. Dark accent text has 11.88:1 against
the dark page. The transparent in-app bird retains its original artwork.

The built-in imagegen tool edited the original raster icon. Its output was
downscaled with macOS `sips` to the installed-web-app icons (192 and 512), Apple
touch icon (180), and favicon (32), all under `frontend/assets/`. Icon URLs carry
a palette version to refresh cached assets. An already-installed home-screen app
may require removing and adding its shortcut again to refresh the OS-cached icon.
No native iOS source or extension source was changed by this palette update.

Generation prompt:

> Use case: precise-object-edit. Edit the attached existing Mynah Finds app icon.
> ONLY replace its dark blue square background with a single flat pale sky blue
> #D9EEF7, including the small blue gap between tag and bird. Preserve the black
> outlined charcoal Javan mynah bird and yellow beak, white eye highlight, cream
> price tag, yellow dollar sign, shape, proportions, location, size and all
> foreground artwork exactly. No new elements, no text, no gradient in the
> background, no rounded corners, no extra padding, no border, no mockup. Full
> square app icon with opaque pale sky blue reaching all four edges. Return a
> high resolution square PNG.
