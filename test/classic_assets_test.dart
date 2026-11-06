import 'package:dsh_pet_flutter/core/config/animation_manifest.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('classic manifest and every advertised clip are bundled', (
    tester,
  ) async {
    final manifest = AnimationManifest.parse(
      await rootBundle.loadString('assets/animations/manifest.json'),
    );
    final assets = (await AssetManifest.loadFromAssetBundle(
      rootBundle,
    )).listAssets();
    expect(manifest.names.length, 106);
    for (final name in manifest.names) {
      expect(assets, contains('assets/animations/$name.webp'));
    }
    expect(
      assets.where(
        (p) =>
            p.startsWith('assets/pet3d/') ||
            p.startsWith('assets/rig/') ||
            p.endsWith('.glb'),
      ),
      isEmpty,
    );
    expect(manifest.idle, isNotEmpty);
    expect(manifest.clicks, hasLength(5));
    expect(manifest.drag, isNotEmpty);
    expect(manifest.categories.expand((c) => c.actions), contains('三球抛接'));
  });

  testWidgets('classic idle, click, drag and play clips decode actual frames', (
    tester,
  ) async {
    final manifest = AnimationManifest.parse(
      File('assets/animations/manifest.json').readAsStringSync(),
    );
    for (final name in [
      manifest.idle.first,
      manifest.clicks.first,
      manifest.drag.first,
      '三球抛接',
    ]) {
      await tester.runAsync(() async {
        final bytes = await File('assets/animations/$name.webp').readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          expect(codec.frameCount, greaterThan(1), reason: name);
          final frame = await codec.getNextFrame();
          expect(
            frame.image.width / frame.image.height,
            closeTo(manifest.width / manifest.height, .01),
          );
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      });
    }
  });
}
