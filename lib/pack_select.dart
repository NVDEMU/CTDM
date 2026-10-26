import 'dart:convert';
import 'dart:io';
import 'package:ctdm/utils/wiimm_tools.dart';
import 'package:ctdm/pack_editor.dart';
import 'package:ctdm/utils/exceptions_utils.dart';
import 'package:ctdm/utils/log_utils.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:loading_animation_widget/loading_animation_widget.dart';

class PackSelect extends StatefulWidget {
  const PackSelect({super.key});

  @override
  State<PackSelect> createState() => _PackSelectState();
}

Future<int> extractIso(String source, String dest) async {
  if (source.trim().isEmpty || dest.trim().isEmpty) {
    throw CtdmException(
      "Select a game image and choose a valid workspace before extracting.",
      StackTrace.current,
      "1001",
    );
  }

  final sourceFile = File(source);
  if (!await sourceFile.exists()) {
    throw CtdmException(
      "The selected game image no longer exists. Select the ISO/WBFS again.\n\n$source",
      StackTrace.current,
      "1001",
    );
  }

  final witPath = resolveWiimmTool('wit');
  final destination = Directory(dest);
  final stdoutTail = <String>[];
  final stderrTail = <String>[];
  var availableSpace = 'unavailable';

  try {
    await Directory(path.dirname(dest)).create(recursive: true);

    // Record available space before a multi-gigabyte extraction. This check
    // is diagnostic only: it never rejects a user's disk or ISO up front.
    try {
      final disk = await Process.run(
        'df',
        ['-Pk', path.dirname(dest)],
        runInShell: false,
      );
      final rows = disk.stdout.toString().trim().split(RegExp(r'\r?\n'));
      if (disk.exitCode == 0 && rows.length >= 2) {
        final columns = rows.last.trim().split(RegExp(r'\s+'));
        if (columns.length >= 4) {
          final availableKiB = int.tryParse(columns[3]);
          if (availableKiB != null) {
            availableSpace =
                '${(availableKiB / (1024 * 1024)).toStringAsFixed(2)} GiB';
          }
        }
      }
    } on Object {
      // Keep going; inability to query disk space should not block extraction.
    }

    final sourceBytes = await sourceFile.length();
    logString(
      LogType.INFO,
      'Starting WIT extraction. Source size: '
      '${(sourceBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB; '
      'free disk space: $availableSpace; tool: $witPath',
    );

    // Stream both pipes instead of using Process.run: WIT may print a lot of
    // output while traversing a Wii disc. Process.run buffers all of it in
    // memory, while the streaming form drains the pipes and keeps only a
    // bounded diagnostic tail.
    final process = await Process.start(
      witPath,
      ['EXTRACT', '--source', source, '--DEST', dest],
      runInShell: false,
    );

    Future<void> drainOutput(
      Stream<List<int>> stream,
      List<String> tail,
    ) async {
      await for (final line
          in stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (tail.length >= 60) tail.removeAt(0);
        tail.add(line);
      }
    }

    final stdoutDone = drainOutput(process.stdout, stdoutTail);
    final stderrDone = drainOutput(process.stderr, stderrTail);
    final exitCode = await process.exitCode;
    await Future.wait<void>([stdoutDone, stderrDone]);

    if (exitCode != 0 || !await destination.exists()) {
      final details = [
        "Wiimm ISO Tool failed to extract the selected game image.",
        "Exit code: $exitCode",
        if (exitCode == -9)
          "WIT was terminated by SIGKILL (-9). This is not a normal WIT "
              "error code. The app sandbox has been removed from this "
              "desktop build so the helper can access the selected ISO; "
              "streamed output and free disk space are included below.",
        "Tool: $witPath",
        "Source: $source",
        "Source size: ${(sourceBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB",
        "Destination: $dest",
        "Free disk space before extraction: $availableSpace",
        if (stderrTail.isNotEmpty)
          "Last WIT error output:\n${stderrTail.join('\n')}",
        if (stdoutTail.isNotEmpty)
          "Last WIT output:\n${stdoutTail.join('\n')}",
      ].join("\n\n");

      logString(LogType.ERROR, "ERROR 1001: $details");
      throw CtdmException(details, StackTrace.current, "1001");
    }

    final ProcessResult regionResult = await Process.run(
      witPath,
      ['DUMP', source, '--show', 'D-ID'],
      runInShell: false,
    );
    if (regionResult.exitCode != 0) {
      logString(
        LogType.WARNING,
        "Could not detect game region after extraction: "
        "${regionResult.stderr}",
      );
    }

    if (regionResult.stdout.toString().contains('RMCK01')) {
      String originalDiscPath = dest;
      if (await Directory(path.join(originalDiscPath, 'DATA')).exists()) {
        originalDiscPath = path.join(originalDiscPath, 'DATA');
      }
      final sceneDir = Directory(
        path.join(originalDiscPath, 'files', 'Scene', 'UI'),
      );

      if (await sceneDir.exists()) {
        final files = await sceneDir.list().toList();
        for (final entity in files) {
          if (entity is! File ||
              !path.basename(entity.path).contains('_R.szs')) {
            continue;
          }
          final targetPath = entity.path.replaceAll('_R.szs', '.szs');
          await entity.copy(targetPath);
          await entity.delete();
        }
      }
    }
    return exitCode;
  } on CtdmException {
    rethrow;
  } on ProcessException catch (error) {
    final details =
        "Could not launch Wiimm ISO Tool.\n\nExecutable: $witPath\n"
        "Reason: ${error.message}\n"
        "Confirm that the bundled WIT executable can start.";
    logString(LogType.ERROR, "ERROR 1001: $details");
    throw CtdmException(details, StackTrace.current, "1001");
  } on FileSystemException catch (error) {
    final details =
        "Could not write the extracted game files.\n\n"
        "Destination: $dest\nReason: ${error.message}";
    logString(LogType.ERROR, "ERROR 1001: $details");
    throw CtdmException(details, StackTrace.current, "1001");
  }
}
class _PackSelectState extends State<PackSelect> {
  late SharedPreferences prefs;
  late String workspace = "";
  late bool isoExtracted = false;
  bool isLoading = false;
  List<Directory> packs = [];
  @override
  void initState() {
    super.initState();
    loadSettings();
  }

  void addPack() {
    if (workspace == '') return;
    Directory tmp =
        Directory(path.join(workspace, 'Packs')).createTempSync('tmp_pack_');

    //sposta config.txt
    //sposta lecode-VER.bin
    //File()//.copySync

    setState(() {});
    Navigator.push(
        context, MaterialPageRoute(builder: (context) => PackEditor(tmp.path)));
  }

  Future<void> loadSettings() async {
    prefs = await SharedPreferences.getInstance();

    setState(() {
      workspace = prefs.getString('workspace')!;
    });
    if (workspace != "") {
      if (!await Directory(path.join(workspace, 'myTracks')).exists()) {
        Directory(path.join(workspace, 'myTracks')).create();
      }
      if (!await Directory(path.join(workspace, 'myMusic')).exists()) {
        Directory(path.join(workspace, 'myMusic')).create();
      }
      if (!await Directory(path.join(workspace, 'myCharacters')).exists()) {
        Directory(path.join(workspace, 'myCharacters')).create();
      }

      isoExtracted =
          await Directory(path.join(workspace, 'ORIGINAL_DISC')).exists();
      if (!await Directory(path.join(workspace, 'Packs')).exists()) {
        Directory(path.join(workspace, 'Packs')).create();
      }
      final dir = Directory(path.join(workspace, 'Packs'));
      final List<FileSystemEntity> entities = await dir.list().toList();
      final Iterable<Directory> subDir = entities.whereType<Directory>();
      packs = [];
      for (var pack in subDir) {
        packs.add(pack);
      }
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    FilePickerResult? result;

    return Stack(
      alignment: Alignment.topCenter,
      children: [
        if (!isoExtracted)
          Padding(
            padding: const EdgeInsets.only(top: 20.0),
            child: Column(
              children: [
                const Text("one last step."),
                const Text("please now select the Mario Kart iso/wbfs.",
                    style: TextStyle(color: Colors.amberAccent)),
                const Text(
                    "it will be extracted into a folder and it will be used to get the files we want to mod."),
                Padding(
                  padding: const EdgeInsets.only(top: 20.0),
                    child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                    ),
                    onPressed: () async => {
                      result = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ["iso", "wbfs"],
                          lockParentWindow: true),
                      if (result != null && result!.files.first.path != null)
                        {
                          setState(() => isLoading = true),
                          prefs.setString('game', result!.files.first.path!),
                          if (await extractIso(result!.files.first.path!,
                                  path.join(workspace, 'ORIGINAL_DISC')) ==
                              0)
                            {}
                          else
                            {},
                          isoExtracted = await Directory(
                                  path.join(workspace, 'ORIGINAL_DISC'))
                              .exists(),
                          setState(
                            () => isLoading = false,
                          ),
                        }
                    },
                    child: Text(
                      "Select File",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize:
                            Theme.of(context).textTheme.headlineSmall?.fontSize,
                      ),
                    ),
                  ),
                ),
                if (isLoading)
                  Padding(
                    padding: const EdgeInsets.only(top: 20.0),
                    child: Column(
                      children: [
                        LoadingAnimationWidget.fourRotatingDots(
                            color: Colors.amberAccent, size: 50),
                        Padding(
                          padding: const EdgeInsets.only(top: 20.0),
                          child: Text(
                            "   extracting the file...",
                            style: TextStyle(
                                color: Colors.white54,
                                fontSize: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.fontSize),
                          ),
                          
                        ),     Padding(
                          padding: const EdgeInsets.only(top: 12.0),
                          child: Text(
                            "This may take several minutes, don't exit the program.",
                            style: TextStyle(
                                color: Colors.white54,
                                fontSize: Theme.of(context)
                                    .textTheme
                                    .labelMedium?.fontSize
                                    ),
                          ),
                          
                        )
                      ],
                    ),
                  )
              ],
            ),
          ),
        if (isoExtracted)
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 20.0),
                child: Text(
                  "Your Packs",
                  style: TextStyle(
                      fontSize:
                          Theme.of(context).textTheme.headlineMedium?.fontSize),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: MediaQuery.of(context).size.width / 5,
                    vertical: 8),
                child: Center(
                    child: GridView.builder(
                        shrinkWrap: true,
                        itemCount: packs.length + 1,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                                mainAxisExtent: 100,
                                mainAxisSpacing: 40,
                                crossAxisSpacing: 40,
                                maxCrossAxisExtent: 200),
                        itemBuilder: (BuildContext context, int index) {
                          if (index < packs.length) {
                            return SizedBox(
                              child: GestureDetector(
                                onTap: () => {
                                  Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (context) => PackEditor(
                                              packs.elementAt(index).path)))
                                },
                                child: Card(
                                    shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.all(
                                            Radius.circular(10))),
                                    color: Colors.amberAccent,
                                    elevation: 10,
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 8.0),
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Align(
                                            alignment: Alignment.topCenter,
                                            child: FittedBox(
                                              fit: BoxFit.fitWidth,
                                              child: Text(
                                                  path.basename(packs
                                                      .elementAt(index)
                                                      .path),
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                      color: Colors.black)),
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 8.0,
                                                left: 10,
                                                right: 10),
                                            child: FittedBox(
                                              fit: BoxFit.fitWidth,
                                              child: Text(
                                                packs
                                                    .elementAt(index)
                                                    .statSync()
                                                    .modified
                                                    .toString()
                                                    .replaceRange(
                                                        packs
                                                                .elementAt(
                                                                    index)
                                                                .statSync()
                                                                .modified
                                                                .toString()
                                                                .length -
                                                            4,
                                                        null,
                                                        ''),
                                                style: const TextStyle(
                                                    color: Colors.black54),
                                              ),
                                            ),
                                          )
                                        ],
                                      ),
                                    )),
                              ),
                            );
                          } else {
                            return IconButton(
                                icon: const Icon(Icons.add),
                                color: Colors.red,
                                onPressed: () => {addPack()});
                          }
                        })),
              ),
            ],
          ),
      ],
    );
  }
}
