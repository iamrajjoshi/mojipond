# Third-party assets and implementation references

The distributable application includes the complete gemoji MIT notice, Noto
Animated Emoji attribution and CC BY 4.0 links, the GIPHY mark notice, and the
AdaptiveGlyphKit MIT notice in
`Contents/Resources/THIRD-PARTY-NOTICES.txt`. Packaging fails closed if that
resource or its required notices are missing.

## AdaptiveGlyphKit

MojiPond does not link AdaptiveGlyphKit. Its static adaptive-glyph bridge was
informed by the project's HEIC metadata discovery and defensive Objective-C
initializer path, pinned at revision
`33976203876adfb91676f3729199a0f40433a96a`:

<https://github.com/joshlacal/AdaptiveGlyphKit>

The full MIT notice is bundled with the app.

## Powered by GIPHY mark

`Resources/ProviderBranding/PoweredByGIPHY.png` is the unmodified
`PoweredBy_200px-Black_HorizLogo.png` mark from GIPHY's official attribution
archive:

<https://media.giphy.com/giphy-attribution-marks.zip>

It is included only where MojiPond presents GIPHY API results, under GIPHY's
API Terms and branding requirements. GIPHY and the GIPHY logo are trademarks
of GIPHY, Inc. Their inclusion does not imply sponsorship or endorsement of
MojiPond.
