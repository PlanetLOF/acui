// Cache pin + purge tests: the per-vault online-only / available-offline
// choice (persisted in SharedPreferences) and the cache-delete helper.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:acui/provider/cloud_pin_provider.dart';
import 'package:acui/provider/file_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('cloud pin store', () {
    test('unpinned vaults default to online only', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(cloudPinProvider.notifier);

      final pin = await notifier.pinFor('terabox:00/v.ac');
      expect(pin.mode, CloudPinMode.onlineOnly);
      expect(pin.lastSize, isNull);
      expect(pin.lastModTime, isNull);
    });

    test('setMode persists across a fresh container', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(cloudPinProvider.notifier)
          .setMode('terabox:00/v.ac', CloudPinMode.offline);

      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      final pin =
          await fresh.read(cloudPinProvider.notifier).pinFor('terabox:00/v.ac');
      expect(pin.mode, CloudPinMode.offline);
    });

    test('recordSync refreshes the fingerprint but keeps the mode', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(cloudPinProvider.notifier);

      await notifier.setMode('terabox:00/v.ac', CloudPinMode.offline);
      await notifier.recordSync(
        'terabox:00/v.ac',
        12345,
        '2026-09-24T15:23:10+06:30',
      );

      final pin = await notifier.pinFor('terabox:00/v.ac');
      expect(pin.mode, CloudPinMode.offline);
      expect(pin.lastSize, 12345);
      expect(pin.lastModTime, '2026-09-24T15:23:10+06:30');
    });

    test('recording a sync on an unpinned vault keeps online-only', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(cloudPinProvider.notifier);

      await notifier.recordSync('terabox:00/v.ac', 42, '2026-09-24T00:00:00Z');
      final pin = await notifier.pinFor('terabox:00/v.ac');
      expect(pin.mode, CloudPinMode.onlineOnly);
      expect(pin.lastSize, 42);
    });
  });

  group('cache purge', () {
    test('deleteVaultCache removes the vault and its mirror sidecars only', () async {
      final dir = await Directory.systemTemp.createTemp('acui_cache_test');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final vault = File('${dir.path}${Platform.pathSeparator}v.ac');
      await vault.writeAsString('x');
      final header = File('${dir.path}${Platform.pathSeparator}v.ac.mirror.header');
      await header.writeAsString('h');
      final metadata = File(
        '${dir.path}${Platform.pathSeparator}v.ac.mirror.metadata',
      );
      await metadata.writeAsString('m');
      final other = File('${dir.path}${Platform.pathSeparator}other.ac');
      await other.writeAsString('o');
      final otherSide = File(
        '${dir.path}${Platform.pathSeparator}other.ac.mirror.header',
      );
      await otherSide.writeAsString('o');

      await const FileService().deleteVaultCache(vault.path);

      expect(await vault.exists(), isFalse);
      expect(await header.exists(), isFalse);
      expect(await metadata.exists(), isFalse);
      // Sibling vaults are untouched.
      expect(await other.exists(), isTrue);
      expect(await otherSide.exists(), isTrue);
    });
  });
}