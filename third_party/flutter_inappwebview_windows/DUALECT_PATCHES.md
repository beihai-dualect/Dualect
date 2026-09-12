# Dualect Windows WebView patches

This directory vendors `flutter_inappwebview_windows` 0.6.0.

The upstream custom platform view truncates logical Flutter surface sizes and
positions to `size_t` before applying the display scale factor. Resizable panes
can therefore produce a native texture whose physical size differs from the
Flutter texture bounds, causing subtle resampling and blurred text.

Dualect preserves the logical `double` values and rounds only after converting
them to physical pixels. The app also snaps pane boundaries to physical pixels.

When updating the plugin, port the changes in `custom_platform_view.cc`,
`in_app_webview.h`, and `in_app_webview.cpp`, then test at Windows display
scales of 100%, 125%, and 150%.
