// The vault browser: browse plaintext entries in folders (derived from stored
// name prefixes, with `.ackeep` markers persisting empty folders), import from
// the host filesystem, extract / preview / rename / delete / move individual
// files and folders, multi-select (move / extract / delete), toggle
// list/grid view, and open settings.
//
// The scene is mounted by the app shell whenever a vault session is open.
// Every engine operation is dispatched through the vault providers on a
// worker isolate, so this widget is a pure consumer of Riverpod state; the
// only local state is the transient selection set for bulk actions and the
// file dialogs.
//
// File pickers come from `FileService` (file_selector); the whole browser
// body is also a drop zone (`_ImportDropZone`) that imports dragged files and
// folders through the same `importPaths` code path. Vault entries themselves
// are draggable onto visible folder targets to move them within the vault.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../provider/browser_provider.dart';
import '../provider/session_provider.dart';
import 'common/action_sheet.dart';
import 'format.dart';
import 'preview.dart';
import 'vault_model.dart';
import 'vault_settings_sheet.dart';

/// The open vault's file browser.
class VaultBrowserScreen extends ConsumerStatefulWidget {
  const VaultBrowserScreen({super.key});

  @override
  ConsumerState<VaultBrowserScreen> createState() => _VaultBrowserScreenState();
}

class _VaultBrowserScreenState extends ConsumerState<VaultBrowserScreen> {
  /// Keys of the entries selected for bulk actions (`VaultBrowserEntry.key`).
  final Set<String> _selected = {};

  /// True while the multi-select toolbar is active (long-press or the Select
  /// app-bar button turns it on; X or an empty selection turns it off).
  bool _selectionMode = false;

  bool _locking = false;

  static const String _fileKeyPrefix = 'file:';
  static const String _folderKeyPrefix = 'folder:';

  List<String> get _selectedFiles => [
    for (final k in _selected)
      if (k.startsWith(_fileKeyPrefix)) k.substring(_fileKeyPrefix.length),
  ];

  List<String> get _selectedFolders => [
    for (final k in _selected)
      if (k.startsWith(_folderKeyPrefix)) k.substring(_folderKeyPrefix.length),
  ];

  void _toggleSelection(VaultBrowserEntry entry) {
    setState(() {
      if (!_selected.add(entry.key)) {
        _selected.remove(entry.key);
        if (_selected.isEmpty) _selectionMode = false;
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
      _selectionMode = false;
    });
  }

  /// Cover the current scene, close the native vault immediately, then let
  /// the overlay finish over the provider shell. The overlay lives in the
  /// root [Overlay] so it survives the browser being removed from the tree.
  Future<void> _lockVault(WidgetRef ref) async {
    if (_locking) return;
    setState(() => _locking = true);

    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(builder: (_) => const _VaultLockTransition());
    final animationElapsed = Future<void>.delayed(_vaultLockAnimationDuration);
    overlay.insert(entry);
    try {
      // Let the opaque transition cover the browser before the session-backed
      // providers are invalidated by [VaultNotifier.close].
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await ref.read(vaultSessionProvider.notifier).close();
      await animationElapsed;
    } catch (_) {
      // VaultNotifier already treats a dead handle as a successful close. If
      // the transition is interrupted, leave the browser usable.
    } finally {
      entry.remove();
      if (mounted) setState(() => _locking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = ref.watch(vaultFilesProvider);
    final info = ref.watch(vaultInfoProvider);
    final actions = ref.watch(vaultActionsProvider);
    final dir = ref.watch(currentVaultFolderProvider);
    final view = ref.watch(browserViewProvider).value ?? BrowserView.list;
    final sort =
        ref.watch(browserSortProvider).value ?? const VaultSortSettings();
    final inFolder = dir.isNotEmpty;

    // Surface transient results/failures from vault mutations as snackbars.
    ref.listen<String?>(vaultActionsProvider.select((s) => s.notice), (
      _,
      notice,
    ) {
      if (notice != null) showSnack(context, notice);
    });

    final vaultName = info.maybeWhen(
      data: (i) => basenameOf(i.path),
      orElse: () => 'Vault',
    );

    // The visible rows double as the select-all universe in selection mode.
    final entries = files.maybeWhen(
      data: (list) => buildBrowserEntries(list, dir, sort: sort),
      orElse: () => const <VaultBrowserEntry>[],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectionMode
              ? '${_selected.length} selected'
              : (inFolder ? dir : vaultName),
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          tooltip: _selectionMode
              ? 'Exit selection'
              : (inFolder
                    ? 'Up'
                    : (_locking ? 'Locking vault…' : 'Lock vault')),
          onPressed: actions.busy || _locking
              ? null
              : () {
                  if (_selectionMode) {
                    _clearSelection();
                  } else if (inFolder) {
                    _goUp(ref, dir);
                  } else {
                    _lockVault(ref);
                  }
                },
          icon: Icon(
            _selectionMode
                ? Icons.close
                : (inFolder ? Icons.arrow_back : Icons.lock_outline),
          ),
        ),
        actions: _selectionMode
            ? _buildSelectionActions(context, ref, actions, entries)
            : [
                IconButton(
                  tooltip: 'Sort by',
                  onPressed: actions.busy
                      ? null
                      : () => _showSortMenu(context, ref),
                  icon: Icon(_sortIcon(sort.criterion)),
                ),
                IconButton(
                  tooltip: 'Select',
                  onPressed: actions.busy
                      ? null
                      : () => setState(() => _selectionMode = true),
                  icon: const Icon(Icons.checklist),
                ),
                IconButton(
                  tooltip: 'New folder',
                  onPressed: actions.busy
                      ? null
                      : () => _newFolderDialog(context, ref),
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
                IconButton(
                  tooltip: view == BrowserView.grid ? 'List view' : 'Grid view',
                  onPressed: actions.busy
                      ? null
                      : () => ref
                            .read(browserViewProvider.notifier)
                            .select(
                              view == BrowserView.grid
                                  ? BrowserView.list
                                  : BrowserView.grid,
                            ),
                  icon: Icon(
                    view == BrowserView.grid
                        ? Icons.view_list_outlined
                        : Icons.grid_view_outlined,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: actions.busy ? null : () => _refresh(ref),
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: actions.busy
                      ? null
                      : () => showVaultSettings(context),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: actions.busy ? null : () => _showImportMenu(context, ref),
        icon: const Icon(Icons.file_download_outlined),
        label: const Text(
          'IMPORT',
          style: TextStyle(fontSize: 14, letterSpacing: 1),
        ),
      ),
      body: Column(
        children: [
          if (actions.busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _ImportDropZone(
              folderLabel: inFolder ? dir : 'vault root',
              onDrop: (paths) =>
                  ref.read(vaultActionsProvider.notifier).importPaths(paths),
              child: _buildBody(context, ref, files, entries, dir, view),
            ),
          ),
        ],
      ),
    );
  }

  void _goUp(WidgetRef ref, String dir) {
    ref.read(currentVaultFolderProvider.notifier).go(parentOfPath(dir));
  }

  void _enterFolder(WidgetRef ref, String path) {
    ref.read(currentVaultFolderProvider.notifier).go(path);
  }

  /// Build the payload for a drag source. A selected item carries the whole
  /// current selection; dragging an unselected item carries just that item.
  _VaultDragData _dragDataFor(VaultBrowserEntry entry) {
    if (_selected.contains(entry.key) && _selected.isNotEmpty) {
      return _VaultDragData(
        fileNames: _selectedFiles,
        folderPaths: _selectedFolders,
        label: '${_selected.length} selected',
        isSelection: true,
      );
    }
    if (entry.isFolder) {
      return _VaultDragData(
        fileNames: const [],
        folderPaths: [entry.folder!.path],
        label: entry.displayName,
      );
    }
    return _VaultDragData(
      fileNames: [entry.file!.name],
      folderPaths: const [],
      label: entry.displayName,
    );
  }

  bool _canDrop(_VaultDragData data, String destPath) {
    if (ref.read(vaultActionsProvider).busy) return false;
    return canMoveEntries(
      fileNames: data.fileNames,
      folderPaths: data.folderPaths,
      destPath: destPath,
    );
  }

  Future<void> _moveDragged(_VaultDragData data, String destPath) async {
    if (!mounted || !_canDrop(data, destPath)) return;
    final moved = await ref
        .read(vaultActionsProvider.notifier)
        .moveEntries(
          fileNames: data.fileNames,
          folderPaths: data.folderPaths,
          destPath: destPath,
        );
    if (moved && mounted && data.isSelection) _clearSelection();
  }

  Widget _wrapEntryDrag(
    VaultBrowserEntry entry,
    Widget child, {
    required bool enabled,
  }) {
    final data = _dragDataFor(entry);
    return Draggable<_VaultDragData>(
      data: data,
      // Let vertical pointer motion remain a list/grid scroll gesture. Once
      // a horizontal drag starts, the feedback can move in either direction.
      affinity: Axis.horizontal,
      maxSimultaneousDrags: enabled ? 1 : 0,
      feedback: _DragFeedback(data: data),
      childWhenDragging: Opacity(opacity: 0.35, child: child),
      child: child,
    );
  }

  Widget _wrapFolderDropTarget({required String path, required Widget child}) {
    return DragTarget<_VaultDragData>(
      onWillAcceptWithDetails: (details) => _canDrop(details.data, path),
      onAcceptWithDetails: (details) async {
        await _moveDragged(details.data, path);
      },
      builder: (context, candidateData, rejectedData) {
        return _VaultDropHighlight(
          active: candidateData.isNotEmpty,
          rejected: rejectedData.isNotEmpty,
          child: child,
        );
      },
    );
  }

  void _refresh(WidgetRef ref) {
    ref.invalidate(vaultFilesProvider);
    ref.invalidate(vaultInfoProvider);
  }

  Future<void> _pullToRefresh(WidgetRef ref) async {
    ref.invalidate(vaultFilesProvider);
    ref.invalidate(vaultInfoProvider);
    await ref.read(vaultFilesProvider.future);
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<VaultFileInfo>> files,
    List<VaultBrowserEntry> entries,
    String dir,
    BrowserView view,
  ) {
    return files.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 8),
              Text(describeEngineError(e), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _refresh(ref),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const _EmptyDropHint(
            icon: Icons.move_to_inbox_outlined,
            title: 'Drag & drop files to import',
            subtitle: '…or tap IMPORT to pick files or a folder.',
          );
        }
        if (entries.isEmpty) {
          return const _EmptyDropHint(
            icon: Icons.folder_open,
            title: 'This folder is empty',
            subtitle: 'Drop files here to add them, or use IMPORT.',
          );
        }
        return RefreshIndicator(
          onRefresh: () => _pullToRefresh(ref),
          child: view == BrowserView.grid
              ? _buildGrid(context, ref, entries)
              : _buildList(context, ref, entries),
        );
      },
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    List<VaultBrowserEntry> entries,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      // Clearance so the floating IMPORT button never covers the last row's
      // Actions (⋯) popup.
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selected = _selected.contains(entry.key);
        if (_selectionMode) {
          final tile = ListTile(
            leading: entry.isFolder
                ? const Icon(Icons.folder_outlined)
                : _FileLeading(file: entry.file!),
            title: Text(entry.displayName),
            subtitle: Text(
              entry.isFolder
                  ? (entry.folder!.visibleChildCount == 0
                        ? 'Empty'
                        : '${entry.folder!.visibleChildCount} '
                              '${entry.folder!.visibleChildCount == 1 ? 'item' : 'items'}')
                  : formatBytes(entry.file!.size),
            ),
            selected: selected,
            selectedTileColor: scheme.secondaryContainer.withValues(
              alpha: 0.35,
            ),
            trailing: Checkbox(
              value: selected,
              onChanged: (_) => _toggleSelection(entry),
            ),
            onTap: () => _toggleSelection(entry),
            onLongPress: () => _toggleSelection(entry),
          );
          return _wrapEntryDrag(
            entry,
            entry.isFolder
                ? _wrapFolderDropTarget(path: entry.folder!.path, child: tile)
                : tile,
            enabled: !ref.read(vaultActionsProvider).busy,
          );
        }
        if (entry.isFolder) {
          final folder = entry.folder!;
          final tile = ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder.name),
            subtitle: Text(
              folder.visibleChildCount == 0
                  ? 'Empty'
                  : '${folder.visibleChildCount} '
                        '${folder.visibleChildCount == 1 ? 'item' : 'items'}',
            ),
            trailing: IconButton(
              tooltip: 'Actions',
              onPressed: () => _showFolderActions(context, ref, folder),
              icon: const Icon(Icons.more_vert),
            ),
            onTap: () => _enterFolder(ref, folder.path),
            onLongPress: () {
              setState(() {
                _selectionMode = true;
                _selected.add(entry.key);
              });
            },
          );
          return _wrapEntryDrag(
            entry,
            _wrapFolderDropTarget(path: folder.path, child: tile),
            enabled: !ref.read(vaultActionsProvider).busy,
          );
        }
        final file = entry.file!;
        final tile = ListTile(
          leading: _FileLeading(file: file),
          title: Text(entry.displayName),
          subtitle: Text(formatBytes(file.size)),
          trailing: IconButton(
            tooltip: 'Actions',
            onPressed: () => _showFileActions(context, ref, file),
            icon: const Icon(Icons.more_vert),
          ),
          onTap: () => _preview(context, ref, file),
          onLongPress: () {
            setState(() {
              _selectionMode = true;
              _selected.add(entry.key);
            });
          },
        );
        return _wrapEntryDrag(
          entry,
          tile,
          enabled: !ref.read(vaultActionsProvider).busy,
        );
      },
    );
  }

  Widget _buildGrid(
    BuildContext context,
    WidgetRef ref,
    List<VaultBrowserEntry> entries,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.05,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selected = _selected.contains(entry.key);
        final String subtitle = entry.isFolder
            ? (entry.folder!.visibleChildCount == 0
                  ? 'Empty'
                  : '${entry.folder!.visibleChildCount} '
                        '${entry.folder!.visibleChildCount == 1 ? 'item' : 'items'}')
            : formatBytes(entry.file!.size);
        final card = Card(
          clipBehavior: Clip.antiAlias,
          color: selected
              ? scheme.secondaryContainer.withValues(alpha: 0.45)
              : null,
          child: InkWell(
            onTap: () {
              if (_selectionMode) {
                _toggleSelection(entry);
              } else if (entry.isFolder) {
                _enterFolder(ref, entry.folder!.path);
              } else {
                _preview(context, ref, entry.file!);
              }
            },
            onLongPress: () {
              if (_selectionMode) {
                _toggleSelection(entry);
              } else {
                setState(() {
                  _selectionMode = true;
                  _selected.add(entry.key);
                });
              }
            },
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _GridTileVisual(entry: entry),
                      if (_selectionMode)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: _TileCheckBadge(checked: selected),
                        )
                      else
                        Positioned(
                          top: 4,
                          right: 4,
                          child: _TileActionsButton(
                            onPressed: () => entry.isFolder
                                ? _showFolderActions(
                                    context,
                                    ref,
                                    entry.folder!,
                                  )
                                : _showFileActions(context, ref, entry.file!),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                  child: Column(
                    children: [
                      Text(
                        entry.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
        return _wrapEntryDrag(
          entry,
          entry.isFolder
              ? _wrapFolderDropTarget(path: entry.folder!.path, child: card)
              : card,
          enabled: !ref.read(vaultActionsProvider).busy,
        );
      },
    );
  }

  void _showImportMenu(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(vaultActionsProvider.notifier);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => ActionSheet(
        title: 'IMPORT INTO VAULT',
        children: [
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: const Text('Import files…'),
            subtitle: const Text('Add one or more plaintext files'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              notifier.importFiles();
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Import folder…'),
            subtitle: const Text('Import a folder with its whole tree'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              notifier.importFolder();
            },
          ),
        ],
      ),
    );
  }

  void _showSortMenu(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(browserSortProvider.notifier);
    final current =
        ref.read(browserSortProvider).value ?? const VaultSortSettings();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => ActionSheet(
        title: 'SORT BY',
        children: [
          for (final criterion in VaultSort.values)
            ListTile(
              leading: Icon(_sortIcon(criterion)),
              title: Text(_sortLabel(criterion)),
              trailing: current.criterion == criterion
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                Navigator.of(sheetContext).pop();
                notifier.selectCriterion(criterion);
              },
            ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              current.descending ? Icons.arrow_downward : Icons.arrow_upward,
            ),
            title: Text(current.descending ? 'Descending' : 'Ascending'),
            subtitle: const Text('Reverse the current sort order'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              notifier.selectSettings(
                current.withDescending(!current.descending),
              );
            },
          ),
        ],
      ),
    );
  }

  static String _sortLabel(VaultSort criterion) => switch (criterion) {
    VaultSort.name => 'Name',
    VaultSort.modified => 'Date modified',
    VaultSort.size => 'Size',
  };

  static IconData _sortIcon(VaultSort criterion) => switch (criterion) {
    VaultSort.name => Icons.sort_by_alpha,
    VaultSort.modified => Icons.update,
    VaultSort.size => Icons.data_usage,
  };

  /// App-bar toolbar replacing the normal actions while multi-select mode is
  /// active: select-all plus bulk Move / Extract / Delete.
  List<Widget> _buildSelectionActions(
    BuildContext context,
    WidgetRef ref,
    VaultActionsState actions,
    List<VaultBrowserEntry> entries,
  ) {
    final allSelected =
        entries.isNotEmpty && entries.every((e) => _selected.contains(e.key));
    return [
      IconButton(
        tooltip: allSelected ? 'Deselect all' : 'Select all',
        onPressed: actions.busy
            ? null
            : () => setState(() {
                if (allSelected) {
                  _selected.clear();
                } else {
                  _selected.addAll([for (final e in entries) e.key]);
                }
              }),
        icon: const Icon(Icons.select_all),
      ),
      IconButton(
        tooltip: 'Move to…',
        onPressed: actions.busy ? null : () => _moveSelection(context, ref),
        icon: const Icon(Icons.drive_file_move_outlined),
      ),
      IconButton(
        tooltip: 'Extract…',
        onPressed: actions.busy ? null : () => _extractSelection(ref),
        icon: const Icon(Icons.file_download_outlined),
      ),
      IconButton(
        tooltip: 'Delete…',
        onPressed: actions.busy ? null : () => _deleteSelection(context, ref),
        icon: const Icon(Icons.delete_outline),
      ),
    ];
  }

  /// Bulk move the selected entries: pick a target through [_moveDialog];
  /// the selection is cleared only when a move actually runs.
  Future<void> _moveSelection(BuildContext context, WidgetRef ref) =>
      _moveDialog(
        context,
        ref,
        fileNames: _selectedFiles,
        folderPaths: _selectedFolders,
      );

  /// Bulk extract the selected entries into a picked directory.
  Future<void> _extractSelection(WidgetRef ref) async {
    await ref
        .read(vaultActionsProvider.notifier)
        .extractEntries(
          fileNames: _selectedFiles,
          folderPaths: _selectedFolders,
        );
    _clearSelection();
  }

  /// Confirm and bulk-delete the selected entries (folders with everything
  /// inside them).
  Future<void> _deleteSelection(BuildContext context, WidgetRef ref) async {
    final files = _selectedFiles;
    final folders = _selectedFolders;
    if (files.isEmpty && folders.isEmpty) return;
    final count = files.length + folders.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete items'),
        content: Text(
          'Remove ${count == 1 ? '1 item' : '$count items'} from the vault? '
          'Folders are deleted with everything inside them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref
          .read(vaultActionsProvider.notifier)
          .deleteEntries(fileNames: files, folderPaths: folders);
      _clearSelection();
    }
  }

  void _showFolderActions(
    BuildContext context,
    WidgetRef ref,
    VaultFolder folder,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => ActionSheet(
        title: folder.name,
        subtitle: folder.visibleChildCount == 0
            ? 'Empty folder · ${formatBytes(folder.size)}'
            : '${folder.visibleChildCount} ${folder.visibleChildCount == 1 ? 'item' : 'items'} · ${formatBytes(folder.size)}',
        titleIsLabel: false,
        children: [
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Open'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _enterFolder(ref, folder.path);
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('View information'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _showFolderInformation(context, folder);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _renameFolderDialog(context, ref, folder);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outlined),
            title: const Text('Move to…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _moveDialog(
                context,
                ref,
                fileNames: [],
                folderPaths: [folder.path],
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Extract…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              ref
                  .read(vaultActionsProvider.notifier)
                  .extractFolder(folder.path);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _deleteFolderDialog(context, ref, folder);
            },
          ),
        ],
      ),
    );
  }

  void _showFileActions(
    BuildContext context,
    WidgetRef ref,
    VaultFileInfo file,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => ActionSheet(
        title: basenameOf(file.name),
        subtitle: formatBytes(file.size),
        titleIsLabel: false,
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('View information'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _showFileInformation(context, file);
            },
          ),
          ListTile(
            leading: const Icon(Icons.visibility_outlined),
            title: const Text('Preview'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _preview(context, ref, file);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outlined),
            title: const Text('Move to…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _moveDialog(
                context,
                ref,
                fileNames: [file.name],
                folderPaths: [],
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Extract…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              ref.read(vaultActionsProvider.notifier).extract(file);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _renameDialog(context, ref, file);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _deleteFile(context, ref, file);
            },
          ),
        ],
      ),
    );
  }

  void _preview(BuildContext context, WidgetRef ref, VaultFileInfo file) {
    showDialog<void>(
      context: context,
      // With media_kit removed there is no video decode/preview, so videos
      // open a placeholder dialog instead of _PreviewDialog.
      builder: (_) => isVideoName(file.name)
          ? _VideoPlaceholderDialog(file: file)
          : _PreviewDialog(name: file.name),
    );
  }

  void _showFileInformation(BuildContext context, VaultFileInfo file) {
    _showInformationDialog(
      context,
      location: file.name,
      size: file.size,
      type: vaultEntryType(file.name),
      storageUsed: file.storageUsed,
      createdAt: file.createdAt,
      modifiedAt: file.modifiedAt,
    );
  }

  void _showFolderInformation(BuildContext context, VaultFolder folder) {
    _showInformationDialog(
      context,
      location: folder.path,
      size: folder.size,
      type: 'Folder',
      storageUsed: folder.storageUsed,
      createdAt: folder.createdAt,
      modifiedAt: folder.modifiedAt,
    );
  }

  void _showInformationDialog(
    BuildContext context, {
    required String location,
    required int size,
    required String type,
    required int storageUsed,
    required int createdAt,
    required int modifiedAt,
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => _InformationDialog(
        location: location,
        size: size,
        type: type,
        storageUsed: storageUsed,
        createdAt: createdAt,
        modifiedAt: modifiedAt,
      ),
    );
  }

  /// True when an entry named [name] already exists in the current folder.
  Future<bool> _nameExists(WidgetRef ref, String name) async {
    final dir = ref.read(currentVaultFolderProvider);
    final files = await ref.read(vaultFilesProvider.future);
    return buildBrowserEntries(files, dir).any((e) => e.displayName == name);
  }

  String _joinDir(WidgetRef ref, String segment) {
    final dir = ref.read(currentVaultFolderProvider);
    return dir.isEmpty ? segment : '$dir/$segment';
  }

  /// Submit a dialog's text field with [value]. The pop is deferred one frame:
  /// popping synchronously inside `TextField.onSubmitted` (which runs inside
  /// the IME/editing callback) tears the dialog subtree down while
  /// `EditableText` is still mid-edit-cycle, which trips framework assertions
  /// ("Tried to build dirty widget in the wrong build scope" / the
  /// `_dependents.isEmpty` assert in `InheritedElement.debugDeactivated`).
  void _submitDialog(BuildContext dialogContext, String value) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (dialogContext.mounted) Navigator.of(dialogContext).pop(value);
    });
  }

  /// Pick a move target from the vault's folder tree — vault root, any existing
  /// folder, or a brand-new folder created on the spot — then relocate
  /// [fileNames] + [folderPaths] there. Returns whether a move ran.
  ///
  /// The current folder is not offered (moving within it is a no-op), and when
  /// folders are being moved their own subtree is hidden too (a folder cannot
  /// move into itself).
  Future<bool> _moveDialog(
    BuildContext context,
    WidgetRef ref, {
    required List<String> fileNames,
    required List<String> folderPaths,
  }) async {
    final files = await ref.read(vaultFilesProvider.future);
    if (!context.mounted) return false;
    final folders = allFolderPaths(files).toList()..sort();
    final currentDir = ref.read(currentVaultFolderProvider);

    final excluded = <String>{currentDir};
    for (final folder in folderPaths) {
      excluded.add(folder);
      excluded.addAll(folders.where((f) => f.startsWith('$folder/')));
    }

    final selectedCount = fileNames.length + folderPaths.length;
    final itemWord = selectedCount == 1 ? '1 item' : '$selectedCount items';

    final target = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Move $itemWord to…'),
        contentPadding: const EdgeInsets.only(top: 8, bottom: 8),
        content: SizedBox(
          width: 380,
          height: 340,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('New folder…'),
                subtitle: const Text('Create a folder and move into it'),
                onTap: () => Navigator.of(dialogContext).pop('__new__'),
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.home_outlined),
                title: const Text('Vault root'),
                onTap: () => Navigator.of(dialogContext).pop(''),
              ),
              for (final f in folders)
                if (!excluded.contains(f))
                  ListTile(
                    dense: true,
                    leading: Padding(
                      padding: EdgeInsets.only(
                        left: (f.split('/').length - 1) * 12.0,
                      ),
                      child: const Icon(Icons.folder_outlined),
                    ),
                    title: Text(basenameOf(f)),
                    subtitle: Text(f, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.of(dialogContext).pop(f),
                  ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (target == null || !context.mounted) return false;

    var destPath = target;
    if (target == '__new__') {
      final created = await _newFolderDialog(context, ref);
      if (created == null) return false;
      destPath = created;
    }
    final moved = await ref
        .read(vaultActionsProvider.notifier)
        .moveEntries(
          fileNames: fileNames,
          folderPaths: folderPaths,
          destPath: destPath,
        );
    if (moved) _clearSelection();
    return moved;
  }

  Future<String?> _newFolderDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (v) => _submitDialog(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !context.mounted) return null;
    final trimmed = name.trim();
    if (!isValidFolderName(trimmed)) {
      showSnack(context, 'Invalid folder name.');
      return null;
    }
    if (await _nameExists(ref, trimmed)) {
      if (!context.mounted) return null;
      showSnack(
        context,
        'A file or folder named "$trimmed" already exists here.',
      );
      return null;
    }
    final created = await ref
        .read(vaultActionsProvider.notifier)
        .createFolder(trimmed);
    return created ? _joinDir(ref, trimmed) : null;
  }

  Future<void> _renameFolderDialog(
    BuildContext context,
    WidgetRef ref,
    VaultFolder folder,
  ) async {
    final controller = TextEditingController(text: folder.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (v) => _submitDialog(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || newName == folder.name || !context.mounted) {
      return;
    }
    final trimmed = newName.trim();
    if (!isValidFolderName(trimmed)) {
      showSnack(context, 'Invalid folder name.');
      return;
    }
    final siblings = await _nameExists(ref, trimmed);
    if (siblings) {
      if (!context.mounted) return;
      showSnack(
        context,
        'A file or folder named "$trimmed" already exists here.',
      );
      return;
    }
    await ref
        .read(vaultActionsProvider.notifier)
        .renameFolder(folder.path, trimmed);
  }

  Future<void> _deleteFolderDialog(
    BuildContext context,
    WidgetRef ref,
    VaultFolder folder,
  ) async {
    final notifier = ref.read(vaultActionsProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete folder'),
        content: Text(
          'Remove "${folder.name}" and all of its contents from the vault?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await notifier.deleteFolder(folder.path);
    }
  }

  Future<void> _renameDialog(
    BuildContext context,
    WidgetRef ref,
    VaultFileInfo file,
  ) async {
    final notifier = ref.read(vaultActionsProvider.notifier);
    final controller = TextEditingController(text: basenameOf(file.name));
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Stored name'),
          onSubmitted: (v) => _submitDialog(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null ||
        newName.isEmpty ||
        newName == basenameOf(file.name) ||
        !context.mounted) {
      return;
    }
    if (newName.contains('/') || newName.contains('\\')) {
      showSnack(context, 'Renames stay within the current folder.');
      return;
    }
    if (isReservedEntryName(newName)) {
      showSnack(context, 'The name ".ackeep" is reserved for folder markers.');
      return;
    }
    if (await _nameExists(ref, newName)) {
      if (!context.mounted) return;
      showSnack(
        context,
        'A file or folder named "$newName" already exists here.',
      );
      return;
    }
    await notifier.rename(file.name, _joinDir(ref, newName));
  }

  Future<void> _deleteFile(
    BuildContext context,
    WidgetRef ref,
    VaultFileInfo file,
  ) async {
    final notifier = ref.read(vaultActionsProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete file'),
        content: Text('Remove "${basenameOf(file.name)}" from the vault?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await notifier.delete(file.name);
    }
  }
}

const _vaultLockAnimationDuration = Duration(milliseconds: 480);

/// A root-overlay lock transition that remains visible while the browser is
/// removed and the provider shell takes its place.
class _VaultLockTransition extends StatelessWidget {
  const _VaultLockTransition();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Positioned.fill(
      child: AbsorbPointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: _vaultLockAnimationDuration,
          builder: (context, progress, child) {
            final appear = Curves.easeOutCubic.transform(
              (progress / 0.55).clamp(0.0, 1.0),
            );
            final exit = Curves.easeInCubic.transform(
              ((progress - 0.72) / 0.28).clamp(0.0, 1.0),
            );
            return ColoredBox(
              color: scheme.surface.withValues(alpha: 1 - exit),
              child: Center(
                child: Opacity(
                  opacity: appear * (1 - exit),
                  child: Transform.scale(
                    scale: 0.72 + (0.28 * appear),
                    child: child,
                  ),
                ),
              ),
            );
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 56, color: scheme.primary),
              const SizedBox(height: 12),
              Text(
                'LOCKING VAULT',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The data carried by an internal vault-item drag. File names and folder
/// paths are kept separately because folders expand to their complete stored
/// subtree in [VaultActionsNotifier.moveEntries].
class _VaultDragData {
  _VaultDragData({
    required List<String> fileNames,
    required List<String> folderPaths,
    required this.label,
    this.isSelection = false,
  }) : fileNames = List.unmodifiable(fileNames),
       folderPaths = List.unmodifiable(folderPaths);

  final List<String> fileNames;
  final List<String> folderPaths;
  final String label;
  final bool isSelection;
}

/// Compact feedback shown under the pointer while an item is being dragged.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.data});

  final _VaultDragData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.drive_file_move_outlined,
                  color: scheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    data.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Highlights a valid folder destination while an internal drag hovers over
/// it. Invalid targets get a subdued error treatment so a rejected drop is
/// visible rather than silently ignored.
class _VaultDropHighlight extends StatelessWidget {
  const _VaultDropHighlight({
    required this.active,
    required this.rejected,
    required this.child,
  });

  final bool active;
  final bool rejected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : (rejected ? scheme.error : null);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: color == null
          ? null
          : BoxDecoration(
              color: active
                  ? scheme.primary.withValues(alpha: 0.10)
                  : scheme.error.withValues(alpha: 0.06),
              border: Border.all(color: color, width: 2),
              borderRadius: BorderRadius.circular(10),
            ),
      child: child,
    );
  }
}

/// The visible `⋯` affordance overlaid on a grid tile's top-right corner, so
/// grid tiles offer the same per-item action sheet that list rows expose via
/// their trailing button (previously grid actions were hidden behind
/// long-press only).
class _TileActionsButton extends StatelessWidget {
  const _TileActionsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.88),
      shape: const CircleBorder(),
      elevation: 1,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.more_vert,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Selection checkmark shown over a grid tile while multi-select mode is
/// active.
class _TileCheckBadge extends StatelessWidget {
  const _TileCheckBadge({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surface.withValues(alpha: 0.88),
      ),
      padding: const EdgeInsets.all(2),
      child: Icon(
        checked ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 22,
        color: checked ? scheme.primary : scheme.outline,
      ),
    );
  }
}

/// The top visual zone of a grid tile: a real raster thumbnail for image
/// files, a movie icon with a play badge for videos, and the plain type icon
/// for folders and other files. The zone keeps a consistent aspect ratio so
/// tiles stay uniform regardless of the source image's proportions.
class _GridTileVisual extends ConsumerWidget {
  const _GridTileVisual({required this.entry});

  final VaultBrowserEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: SizedBox.expand(child: _buildVisual(context, ref)),
    );
  }

  Widget _buildVisual(BuildContext context, WidgetRef ref) {
    if (entry.isFolder) {
      return const Center(child: Icon(Icons.folder_outlined, size: 40));
    }
    final file = entry.file!;
    if (isVideoName(file.name)) {
      return const Center(child: Icon(Icons.movie_outlined, size: 40));
    }
    if (isImageName(file.name)) {
      const placeholder = Center(child: Icon(Icons.image_outlined, size: 32));
      return ref
          .watch(vaultImageThumbProvider(file.name))
          .when(
            loading: () => placeholder,
            error: (_, _) => placeholder,
            data: (bytes) => Image.memory(
              bytes,
              fit: BoxFit.cover,
              cacheWidth: 220,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => placeholder,
            ),
          );
    }
    return const Center(child: Icon(Icons.description_outlined, size: 40));
  }
}

/// A 40×40 rounded raster thumbnail for image rows in list view; the generic
/// file icon otherwise.
class _FileLeading extends ConsumerWidget {
  const _FileLeading({required this.file});

  final VaultFileInfo file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isVideoName(file.name)) {
      return const Icon(Icons.movie_outlined);
    }
    if (!isImageName(file.name)) {
      return const Icon(Icons.description_outlined);
    }
    const placeholder = Icon(Icons.description_outlined);
    return ref
        .watch(vaultImageThumbProvider(file.name))
        .when(
          loading: () => placeholder,
          error: (_, _) => placeholder,
          data: (bytes) => ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(
              bytes,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              cacheWidth: 80,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => placeholder,
            ),
          ),
        );
  }
}

/// What opens when a video is tapped. media_kit was removed, so there is no
/// decoder or preview for videos anymore — the dialog just identifies the
/// file and points at Extract. Deliberately minimal and read-free.
class _VideoPlaceholderDialog extends StatelessWidget {
  const _VideoPlaceholderDialog({required this.file});

  final VaultFileInfo file;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(basenameOf(file.name)),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.movie_outlined, size: 40),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              '${formatBytes(file.size)}\n'
              'Video preview is not available — use Extract to view it.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Modal preview of a non-video entry; reads the file through
/// [vaultPreviewProvider] so the loading/error states live inside the dialog,
/// then renders it by kind — images/SVG natively, text as selectable
/// monospace, anything else as a hex dump (see `preview.dart`). Videos open
/// [_VideoPlaceholderDialog] instead.
class _PreviewDialog extends ConsumerWidget {
  const _PreviewDialog({required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(vaultPreviewProvider(name));
    final notifier = ref.read(vaultActionsProvider.notifier);

    return AlertDialog(
      title: Text(basenameOf(name)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 400),
        child: preview.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Text('Failed to preview: ${describeEngineError(e)}'),
          ),
          data: (p) {
            final sizeLine =
                '${formatBytes(p.fullSize)} · '
                '${p.truncated ? 'first ${formatBytes(previewCap)} shown' : 'full file'}';
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sizeLine, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                Flexible(
                  child: _PreviewBody(
                    kind: previewKindOf(name, p.bytes),
                    bytes: p.bytes,
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        ...?preview.maybeWhen(
          data: (p) => [
            OutlinedButton.icon(
              onPressed: () => notifier.saveFileAs(name, p.bytes),
              icon: const Icon(Icons.save_alt),
              label: const Text('Save as…'),
            ),
          ],
          orElse: () => const <Widget>[],
        ),
      ],
    );
  }
}

class _InformationDialog extends StatelessWidget {
  const _InformationDialog({
    required this.location,
    required this.size,
    required this.type,
    required this.storageUsed,
    required this.createdAt,
    required this.modifiedAt,
  });

  final String location;
  final int size;
  final String type;
  final int storageUsed;
  final int createdAt;
  final int modifiedAt;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Information'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InformationRow(label: 'Location', value: location),
              _InformationRow(label: 'Size', value: formatBytes(size)),
              _InformationRow(label: 'Type', value: type),
              _InformationRow(
                label: 'Storage used',
                value: formatBytes(storageUsed),
              ),
              _InformationRow(
                label: 'Created',
                value: formatVaultTimestamp(createdAt),
              ),
              _InformationRow(
                label: 'Modified',
                value: formatVaultTimestamp(modifiedAt),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _InformationRow extends StatelessWidget {
  const _InformationRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

/// Renders a file's bytes according to its [PreviewKind]: images and SVG
/// natively (falling back to the hex view when the decoder rejects them),
/// text as selectable monospace, everything else as a hex dump.
class _PreviewBody extends StatelessWidget {
  const _PreviewBody({required this.kind, required this.bytes});

  final PreviewKind kind;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    switch (kind) {
      case PreviewKind.image:
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _HexView(bytes: bytes),
        );
      case PreviewKind.svg:
        return SvgPicture.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _HexView(bytes: bytes),
        );
      case PreviewKind.video:
        return Stack(
          alignment: Alignment.center,
          children: [
            Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _HexView(bytes: bytes),
            ),
            const Icon(Icons.play_circle_fill, size: 56, color: Colors.white70),
          ],
        );
      case PreviewKind.text:
        return SingleChildScrollView(
          child: SelectableText(
            decodeText(bytes),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        );
      case PreviewKind.binary:
        return _HexView(bytes: bytes);
    }
  }
}

/// A monospace hex dump of the preview content (capped rows so a large read
/// never blows up the dialog).
class _HexView extends StatelessWidget {
  const _HexView({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: SelectableText(
        hexDump(bytes),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}

/// Turns the whole browser body into a drop zone: while an OS drag hovers over
/// the file area an overlay explains that the drop imports into the current
/// vault folder, and on drop the dropped filesystem paths are handed to
/// [VaultActionsNotifier.importPaths] — files land in the current folder,
/// directories import their whole tree (same semantics as the Import dialogs).
class _ImportDropZone extends StatefulWidget {
  const _ImportDropZone({
    required this.child,
    required this.onDrop,
    required this.folderLabel,
  });

  final Widget child;

  /// Receives the dropped filesystem paths (filtered to non-empty).
  final void Function(List<String> paths) onDrop;

  /// The folder the browser is showing (`''` root label is "vault root"),
  /// used by the drop overlay copy.
  final String folderLabel;

  @override
  State<_ImportDropZone> createState() => _ImportDropZoneState();
}

class _ImportDropZoneState extends State<_ImportDropZone> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        widget.onDrop([
          for (final f in detail.files)
            if (f.path.trim().isNotEmpty) f.path,
        ]);
      },
      child: Stack(
        children: [
          widget.child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: scheme.primary.withValues(alpha: 0.08),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: scheme.primary, width: 2),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 16,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.move_to_inbox_outlined,
                            size: 44,
                            color: scheme.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Drop to import into ${widget.folderLabel}',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Files and folders are added to the '
                            'current vault folder.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The resting placeholder for an empty vault or empty folder: a centered
/// dashed-border card that advertises the browser's drag-and-drop import,
/// so users know they can drop files here even before they hover.
class _EmptyDropHint extends StatelessWidget {
  const _EmptyDropHint({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: CustomPaint(
            painter: _DashedBorderPainter(
              color: scheme.outlineVariant,
              radius: 14,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 44, color: scheme.primary),
                  const SizedBox(height: 14),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints a dashed rounded-rectangle outline — the "drop here" affordance of
/// the empty vault/folder placeholders. Self-contained so the app doesn't
/// need a dashed-border package for one decorative touch.
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const double _dash = 6.0;
  static const double _gap = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    // Stroke the perimeter in a dash/gap rhythm (RRect metrics yield a
    // single contour).
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + _dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += _dash + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
