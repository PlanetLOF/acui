import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Thin wrapper around file_selector so screens never touch the plugin
/// directly.
///
/// Every dialog returns a **filesystem path** (`Uri.toFilePath`), never the
/// URI `.path` form — on Windows `Uri.file(...).path` yields `/C:/...`, which
/// the vault engine rejects with an I/O error (os error 123).
class FileService {
  const FileService();

  static const _vaultExt = ['ac'];

  /// Single-file open dialog for an existing vault.
  Future<String?> pickVault() async {
    const typeGroup = XTypeGroup(label: 'vault', extensions: _vaultExt);
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    return file?.path;
  }

  /// Native "Save as…" dialog for a new vault, pre-filled with `vault.ac`.
  ///
  /// Picks the exact file path (name included); nothing is written to the
  /// filesystem until "CREATE VAULT" really runs — file_selector only
  /// returns a location.
  Future<String?> saveVault() async {
    const typeGroup = XTypeGroup(label: 'vault', extensions: _vaultExt);
    final loc = await getSaveLocation(
      suggestedName: 'vault.ac',
      acceptedTypeGroups: const [typeGroup],
    );
    if (loc == null) return null;
    var path = loc.path;
    // Windows/macOS auto-append the extension in the dialog; Linux does not.
    if (!path.toLowerCase().endsWith('.ac')) path += '.ac';
    return path;
  }

  Future<String?> pickPrivateKey() async {
    final file = await openFile();
    return file?.path;
  }

  /// Multi-file open dialog for importing files into the open vault.
  Future<List<String>> pickImportFiles() async {
    final files = await openFiles();
    return [for (final f in files) f.path];
  }

  /// Folder-open dialog (import folder / extract destination).
  Future<String?> pickDirectory() async {
    return getDirectoryPath();
  }

  /// Save dialog that returns the chosen path; the caller writes [bytes].
  /// (Unlike file_picker, file_selector only picks a location.)
  Future<String?> saveFileAs({
    required String suggestedName,
    required Uint8List bytes,
  }) async {
    final loc = await getSaveLocation(suggestedName: suggestedName);
    if (loc == null) return null;
    await File(loc.path).writeAsBytes(bytes);
    return loc.path;
  }
}

final fileServiceProvider = Provider<FileService>((ref) => const FileService());
