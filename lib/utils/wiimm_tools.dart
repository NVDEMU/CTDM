import 'dart:io';

import 'package:path/path.dart' as path;

/// Resolve Wiimm command-line tools for desktop apps launched from Finder.
///
/// macOS GUI apps do not reliably inherit PATH entries from ~/.zshrc, so
/// check the common per-user Wiimm tool folders before falling back to PATH.
String resolveWiimmTool(String executable) {
  if (!Platform.isMacOS) return executable;

  final home = Platform.environment['HOME'];

  // Prefer the tested copies shipped inside CTDM.app. This makes the macOS
  // distribution self-contained and avoids false "toolset missing" errors
  // caused by Finder's restricted PATH or a user's unrelated tool version.
  final executableDirectory = path.dirname(Platform.resolvedExecutable);
  final contentsDirectory = path.dirname(executableDirectory);
  final bundledRoot = path.join(contentsDirectory, 'Resources', 'CTDM-tools');
  final List<String> bundledRoots;
  if (executable == 'wit' || executable == 'wwt' || executable == 'wdf') {
    bundledRoots = [path.join(bundledRoot, 'wit')];
  } else if (executable == 'ffmpeg' || executable == 'ffprobe') {
    bundledRoots = [path.join(bundledRoot, 'ffmpeg')];
  } else if (executable == 'mpv') {
    bundledRoots = [path.join(bundledRoot, 'mpv')];
  } else {
    bundledRoots = [path.join(bundledRoot, 'szs')];
  }

  final userRoots = <String>[
    if (home != null && home.isNotEmpty)
      path.join(home, 'Tools', 'WiimmSZS'),
    if (home != null && home.isNotEmpty)
      path.join(home, 'Tools', 'WiimmISO'),
    if (home != null && home.isNotEmpty)
      path.join(home, 'Tools', 'mpv'),
    if (home != null && home.isNotEmpty)
      path.join(home, 'Tools', 'FFmpeg'),
  ];

  for (final root in [...bundledRoots, ...userRoots]) {
    final directory = Directory(root);
    if (!directory.existsSync()) continue;

    try {
      for (final entity in directory.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (path.basename(entity.path) != executable) continue;
        if (File(entity.path).existsSync()) return entity.path;
      }
    } on FileSystemException {
      // Skip inaccessible folders and keep searching other install locations.
    }
  }

  final commonDirectories = <String>[
    if (home != null && home.isNotEmpty) path.join(home, '.local', 'bin'),
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/usr/bin',
  ];
  for (final directory in commonDirectories) {
    final candidate = path.join(directory, executable);
    if (File(candidate).existsSync()) return candidate;
  }

  // Retain normal PATH lookup for Windows/Linux and conventional installs.
  return executable;
}
