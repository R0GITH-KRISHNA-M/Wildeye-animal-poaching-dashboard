import 'dart:html' as html;
import 'dart:ui_web' as ui;
import 'package:flutter/widgets.dart';

void registerLiveFeedView() {
  // Register a view factory for the 'live_feed' view type.
  ui.platformViewRegistry.registerViewFactory(
    'live_feed',
    (int viewId) {
      // Create an HTML ImageElement.
      final img = html.ImageElement()
        ..src = 'http://localhost:8000/live' // The MJPEG stream endpoint
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover';
      return img;
    },
  );
}

// This widget will be used in the main app to display the live feed.
Widget buildLiveFeed() => const HtmlElementView(viewType: 'live_feed');