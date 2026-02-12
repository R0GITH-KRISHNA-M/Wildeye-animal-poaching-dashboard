import 'package:flutter/widgets.dart';

// On mobile/desktop, we do nothing.
void registerLiveFeedView() {
  // No-op
}

// Display a placeholder message on non-web platforms.
Widget buildLiveFeed() =>
    const Center(child: Text('Live feed is available on Web only'));