import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'settings.dart' show defaultSettingsValues;
import 'utils/wiimm_tools.dart';

import 'pack_select.dart' show PackSelect, extractIso;

class StudioHome extends StatefulWidget {
  final Color gold;

  const StudioHome({super.key, required this.gold});

  @override
  State<StudioHome> createState() => _StudioHomeState();
}

class _StudioHomeState extends State<StudioHome> {
  String _workspace = '';
  String _gameImage = '';
  bool _discReady = false;
  bool _loading = true;
  bool _extracting = false;
  String _message = 'Choose a workspace to get started.';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Initialize preferences after the UI is alive. Guard all setup to
      // prevent a plugin or preference error from terminating app startup.
      await prefs.setString('version', 'v1.0.0');
      if (!prefs.containsKey('profile')) {
        await prefs.setString('profile', '');
      }
      if (!prefs.containsKey('download_already_check')) {
        await prefs.setBool('download_already_check', false);
      }
      for (final entry in defaultSettingsValues.entries) {
        if (prefs.containsKey(entry.key)) continue;
        if (entry.value is bool) {
          await prefs.setBool(entry.key, entry.value as bool);
        } else {
          await prefs.setString(entry.key, entry.value.toString());
        }
      }

      // Do not spawn command-line processes during startup. The CI build
      // smoke-tests the bundled executables; presence is enough for the UI.
      await prefs.setBool(
        'szs',
        File(resolveWiimmTool('wlect')).existsSync(),
      );
      await prefs.setBool(
        'wit',
        File(resolveWiimmTool('wit')).existsSync(),
      );

      final workspace = prefs.getString('workspace') ?? '';
      final gameImage = prefs.getString('game') ?? '';
      final ready = workspace.isNotEmpty &&
          Directory(path.join(workspace, 'ORIGINAL_DISC')).existsSync();

      if (!mounted) return;
      setState(() {
        _workspace = workspace;
        _gameImage = gameImage;
        _discReady = ready;
        _loading = false;
        if (ready) {
          _message = 'Game files are prepared. You can start building.';
        } else if (workspace.isNotEmpty) {
          _message = 'Workspace is ready. Select your Mario Kart Wii image next.';
        } else {
          _message = 'Choose a workspace to get started.';
        }
      });
    } on Object catch (error, stackTrace) {
      debugPrint('MKW Distribution Maker startup setup failed: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _discReady = false;
        _message = 'Startup setup failed: $error';
      });
      _showMessage('Startup setup failed. Diagnostic details were sent to startup.log.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _chooseWorkspace() async {
    String? selected;
    try {
      selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose your distribution workspace',
      );
    } on Object catch (error, stackTrace) {
      // The previous FilePicker release could fail on macOS without giving
      // users any visible indication. Surface the platform error instead of
      // letting a button appear to do nothing.
      debugPrint('Workspace picker failed: $error\n$stackTrace');
      _showMessage('Could not open the folder picker: $error');
      return;
    }
    if (!mounted || selected == null || selected.isEmpty) return;

    try {
      for (final folder in ['Packs', 'myTracks', 'myMusic', 'myCharacters']) {
        await Directory(path.join(selected, folder)).create(recursive: true);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('workspace', selected);
      await _refresh();
      _showMessage('Workspace selected.');
    } on FileSystemException catch (error) {
      _showMessage('Could not prepare that folder: ' + error.message);
    } on Object catch (error, stackTrace) {
      debugPrint('Workspace setup failed: $error\n$stackTrace');
      _showMessage('Workspace setup failed: $error');
    }
  }

  Future<void> _chooseAndPrepareGame() async {
    if (_workspace.isEmpty) {
      _showMessage('Choose a workspace first.');
      return;
    }

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['iso', 'wbfs'],
        allowMultiple: false,
        dialogTitle: 'Select your Mario Kart Wii ISO or WBFS',
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Game image picker failed: $error\n$stackTrace');
      _showMessage('Could not open the ISO/WBFS picker: $error');
      return;
    }
    if (!mounted || result == null || result.files.isEmpty) return;
    final source = result.files.single.path;
    if (source == null || source.isEmpty) {
      _showMessage('The selected file path could not be read.');
      return;
    }

    final destination = path.join(_workspace, 'ORIGINAL_DISC');
    if (Directory(destination).existsSync()) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Replace prepared game files?'),
          content: const Text(
            'This removes the existing extracted game folder in this workspace '
            'and extracts the newly selected image instead.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true) return;
      try {
        await Directory(destination).delete(recursive: true);
      } on FileSystemException catch (error) {
        _showMessage('Could not replace the old game folder: ' + error.message);
        return;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('game', source);
    if (!mounted) return;
    setState(() {
      _gameImage = source;
      _extracting = true;
      _discReady = false;
      _message = 'Extracting game files. This can take several minutes.';
    });

    try {
      final exitCode = await extractIso(source, destination);
      if (exitCode != 0 || !Directory(destination).existsSync()) {
        throw StateError(
          'The game image could not be extracted (exit ' +
              exitCode.toString() +
              ').',
        );
      }
      if (!mounted) return;
      setState(() {
        _discReady = true;
        _message = 'Game files are prepared. Your distribution is ready to configure.';
      });
      _showMessage('Game files prepared successfully.');
    } on Object catch (error) {
      _showMessage('Could not extract the game image: ' + error.toString());
      if (mounted) {
        setState(() {
          _discReady = false;
          _message = 'Extraction failed. Check the selected image and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  Future<void> _openBuilder() async {
    await _refresh();
    if (_workspace.isEmpty) {
      _showMessage('Choose a workspace first.');
      return;
    }
    if (!_discReady) {
      _showMessage('Select and prepare a Mario Kart Wii image first.');
      return;
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: const Text('Your distributions'),
            leading: IconButton(
              tooltip: 'Back to home',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: const PackSelect(),
        ),
      ),
    );
    await _refresh();
  }

  Widget _buildStep({
    required String number,
    required IconData icon,
    required String title,
    required String description,
    required String status,
    required String action,
    required VoidCallback? onPressed,
    bool complete = false,
    bool busy = false,
  }) {
    final accent = complete ? const Color(0xFF65D6A6) : widget.gold;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, color: accent, size: 21),
                ),
                const Spacer(),
                Text(
                  number,
                  style: TextStyle(
                    color: accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            Text(
              description,
              style: const TextStyle(
                color: Color(0xFFB4BBC6),
                height: 1.4,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : onPressed,
                child: busy
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(action),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final workspaceReady = _workspace.isNotEmpty;
    final gameReady = _discReady;

    return Scaffold(
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(28, 24, 28, 30),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE8494F),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Icon(Icons.flag_rounded, color: Colors.white),
                            ),
                            const SizedBox(width: 13),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'MKW DISTRIBUTION MAKER',
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    'Build custom cups and track distributions for Mario Kart Wii',
                                    style: TextStyle(color: Color(0xFFABB2BE), fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                color: const Color(0xFF20252E),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFF343B48)),
                              ),
                              child: const Text(
                                'RIFTWII / RIIVOLUTION',
                                style: TextStyle(
                                  color: Color(0xFFFFC857),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.7,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(26),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFF29202A),
                                Color(0xFF1A2029),
                                Color(0xFF171A20),
                              ],
                            ),
                            border: Border.all(color: const Color(0xFF3B333A)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'YOUR TRACKS. YOUR CUPS. YOUR DISTRIBUTION.',
                                style: TextStyle(
                                  color: Color(0xFFFFC857),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'Make Mario Kart Wii your own.',
                                style: TextStyle(fontSize: 31, fontWeight: FontWeight.w800, height: 1.1),
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                'Organize custom tracks into cups, save your projects, and export a '
                                'Riivolution-format distribution that RiftWii can load.',
                                style: TextStyle(color: Color(0xFFBCC3CE), fontSize: 14, height: 1.45),
                              ),
                              const SizedBox(height: 20),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  _StatPill(value: '2,048', label: 'cup capacity'),
                                  _StatPill(value: '8,192', label: 'track slots'),
                                  const _StatPill(value: '4', label: 'tracks per racing cup'),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Setup',
                                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                              ),
                            ),
                            Text(
                              _message,
                              style: const TextStyle(color: Color(0xFFB4BBC6), fontSize: 12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 255,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: _buildStep(
                                  number: 'STEP 01',
                                  icon: Icons.folder_open_rounded,
                                  title: 'Choose workspace',
                                  description: 'Keep projects, imported tracks, music, and output packs together.',
                                  status: workspaceReady
                                      ? path.basename(_workspace)
                                      : 'Not configured yet',
                                  action: workspaceReady ? 'Change folder' : 'Choose folder',
                                  onPressed: _chooseWorkspace,
                                  complete: workspaceReady,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _buildStep(
                                  number: 'STEP 02',
                                  icon: Icons.album_rounded,
                                  title: 'Prepare game files',
                                  description: 'Select your own Mario Kart Wii ISO or WBFS image for the distribution base.',
                                  status: gameReady ? 'Game files prepared' : 'ISO / WBFS not prepared',
                                  action: gameReady ? 'Replace image' : 'Select ISO / WBFS',
                                  onPressed: _chooseAndPrepareGame,
                                  complete: gameReady,
                                  busy: _extracting,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _buildStep(
                                  number: 'STEP 03',
                                  icon: Icons.grid_view_rounded,
                                  title: 'Cups & tracks',
                                  description: 'Create a distribution, add cups, import tracks, reorder entries, then build the pack.',
                                  status: gameReady ? 'Ready to build' : 'Finish steps 01 and 02 first',
                                  action: 'Open distribution builder',
                                  onPressed: gameReady ? _openBuilder : null,
                                  complete: gameReady,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 15),
                        Row(
                          children: [
                            const Icon(Icons.offline_bolt_rounded, color: Color(0xFF65D6A6), size: 18),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Standalone setup: Wiimm and media tools are packaged with the app; no separate tool installation is required.',
                                style: TextStyle(color: Color(0xFFABB2BE), fontSize: 12),
                              ),
                            ),
                            if (_gameImage.isNotEmpty)
                              Tooltip(
                                message: _gameImage,
                                child: const Icon(Icons.check_circle_outline, color: Color(0xFF65D6A6), size: 18),
                              ),
                          ],
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

class _StatPill extends StatelessWidget {
  final String value;
  final String label;

  const _StatPill({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF12151A).withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3A3F48)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
          const SizedBox(width: 7),
          Text(label, style: const TextStyle(color: Color(0xFFABB2BE), fontSize: 11)),
        ],
      ),
    );
  }
}
