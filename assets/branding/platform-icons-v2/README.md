# Mynah Finds platform icons v2

Full icon retains a golden yellow dollar sign and charcoal grey string. Small icon is the bird head without tag. Previous artwork is preserved.

- Chrome: copy PNGs into your extension's icons/ directory and merge manifest-snippet.json into your existing manifest. All Chrome sizes use a transparent bird head with a subtle ivory edge for light and dark backgrounds. iOS and web installation icons retain their blue background, yellow dollar sign and charcoal string.
- iOS: import ios/AppIcon.appiconset into Assets.xcassets and select AppIcon as the app icon source. Includes legacy iPhone/iPad slots and opaque 1024px App Store artwork. These are flat raster assets, not layered Icon Composer artwork or bespoke dark/tinted variants.
- Web: copy web files to public/icons/, add head-snippet.html to your page head, and adapt start_url/name in site.webmanifest if needed. 192/512 standard and separately padded maskable icons are supplied. Apple touch icon is 180px. PNG favicons supported by modern browsers; no ICO included.
- Preview: open preview.html to inspect actual-size icons and circular/rounded crops.

Masters were produced using the built-in image generation tool; prompts.txt records exact prompts. export.sh reproduces PNG sizing using macOS sips. Outputs are raster PNGs, not editable SVGs. The generated artwork retains subtle shading. Maskable exports use a separately generated composition with generous blue margins.

Validation: PNG dimensions and appropriate alpha channels and JSON checked locally; small-size and maskable PNGs visually inspected. No actual app build, Chrome install, App Store upload or device test was performed.

