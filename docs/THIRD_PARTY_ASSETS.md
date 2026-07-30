# Third-party assets and implementation references

The distributable application includes the complete gemoji MIT notice, Noto
Animated Emoji attribution and CC BY 4.0 links, and the AdaptiveGlyphKit MIT
notice in
`Contents/Resources/THIRD-PARTY-NOTICES.txt`. Packaging fails closed if that
resource or its required notices are missing.

## AdaptiveGlyphKit

MojiPond does not link AdaptiveGlyphKit. Its adaptive-image-glyph bridge was
informed by the project's HEIC metadata discovery and defensive Objective-C
initializer path, pinned at revision
`33976203876adfb91676f3729199a0f40433a96a`:

<https://github.com/joshlacal/AdaptiveGlyphKit>

The full MIT notice is bundled with the app.
