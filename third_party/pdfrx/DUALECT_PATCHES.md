# Dualect pdfrx patches

This directory vendors pdfrx 2.4.4. Dualect adds three viewer parameters that
are not exposed by the upstream package:

- `pagePaintFilterQuality` controls cached page texture filtering.
- `visibleRenderScaleFactor` supersamples only the visible partial-page render.
- `additionalRenderFlags` passes optional PDFium flags to preview and partial renders.

Dualect currently uses medium texture filtering, 1.12x visible-region
supersampling, a 100 ms settled-render delay, and LCD text rendering in light
themes. Dark themes keep grayscale antialiasing because their PDF view is color
inverted and subpixel rendering can otherwise produce colored fringes.

When updating pdfrx, port the changes in `pdf_viewer.dart` and
`pdf_viewer_params.dart`, then rerun `flutter analyze`, `flutter test`, and a
Windows build.
