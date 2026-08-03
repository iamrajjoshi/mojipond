# Third-party assets and implementation references

The distributable application includes the complete gemoji, AdaptiveGlyphKit,
and Sentry Cocoa MIT notices in
`Contents/Resources/THIRD-PARTY-NOTICES.txt`. Sentry's transitive notices and
Sparkle's license ship as separate resources. Packaging fails closed if a
required notice is missing.

## AdaptiveGlyphKit

MojiPond does not link AdaptiveGlyphKit. Its adaptive-image-glyph bridge was
informed by the project's HEIC metadata discovery and defensive Objective-C
initializer path, pinned at revision
`33976203876adfb91676f3729199a0f40433a96a`:

<https://github.com/joshlacal/AdaptiveGlyphKit>

The full MIT notice is bundled with the app.
