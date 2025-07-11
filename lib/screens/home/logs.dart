import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../utils/method_channel.dart';
import '../../utils/runtime_platform.dart';

class LogViewer extends StatefulWidget {
  final String filePath;
  final int maxLines;

  const LogViewer({super.key, required this.filePath, this.maxLines = 1000});

  @override
  LogViewerState createState() => LogViewerState();
}

class LogViewerState extends State<LogViewer> {
  static List<String> _logLines = [];
  final ScrollController _scrollController = ScrollController();
  late File _logFile;
  int _lastFileSize = 0;

  @override
  void initState() {
    super.initState();
    _logFile = File(widget.filePath);
    _loadInitialLog();
    _startFileMonitor();
  }

  Timer? _timer;

  @override
  void dispose() {
    super.dispose();
    _scrollController.dispose();
    if (_timer != null) {
      _timer!.cancel();
    }
    mCMan.removeHandler('onFileChange', handleFileChange);
  }

  void _loadInitialLog() {
    // Load the last N lines from the file
    _readLastNLines(widget.maxLines).then((lines) {
      if (mounted) {
        setState(() {
          _logLines = lines;
        });
        // SchedulerBinding.instance.addPostFrameCallback((_) {
        //   _scrollToBottom();
        // });
      }
    });
  }

  Future<List<String>> _readLastNLines(int n) async {
    if (RuntimePlatform.isWeb) {
      return [];
    }

    List<String> lines = [];
    if (!await _logFile.exists()) {
      return [];
    }
    int length = await _logFile.length();
    _lastFileSize = length;

    RandomAccessFile file = await _logFile.open();
    // cull last '\n'
    int endPosition = length - 1;

    // Read file backward until N lines are reached
    while (lines.length < n && endPosition > 0) {
      int startPosition = (endPosition > 1024) ? endPosition - 1024 : 0;
      file.setPositionSync(startPosition);
      String chunk = utf8.decode(await file.read(endPosition - startPosition));
      final newLines = chunk.split('\n');
      // concatenate boundries
      if (lines.isNotEmpty) {
        lines[0] = newLines[newLines.length - 1] + lines[0];
      }
      if (newLines.length > 1) {
        lines = newLines.sublist(0, newLines.length - 1) + lines;
      }

      endPosition = startPosition;
    }

    file.closeSync();

    return lines.sublist(max(0, lines.length - widget.maxLines));
  }

  Future<void> onFileChange() async {
    if (RuntimePlatform.isWeb) {
      return;
    }

    if (!_logFile.existsSync()) {
      return;
    }
    int newSize = await _logFile.length();
    if (newSize > _lastFileSize) {
      final rederedSize = _lastFileSize;
      _lastFileSize = newSize;

      RandomAccessFile file = await _logFile.open();
      file.setPositionSync(rederedSize);
      String appendedText = utf8.decode(await file.read(newSize - rederedSize));
      file.closeSync();

      List<String> newLines = appendedText.split('\n');
      if (newLines[newLines.length - 1] == "") {
        newLines = newLines.sublist(0, newLines.length - 1);
      }
      if (mounted) {
        setState(() {
          _logLines.addAll(newLines);
          if (_logLines.length > widget.maxLines) {
            _logLines = _logLines.sublist(_logLines.length - widget.maxLines);
          }
        });

        if (_scrollController.position.atEdge &&
            _scrollController.position.pixels == 0) {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            _scrollToBottom();
          });
        }
      }
    }
  }

  void handleFileChange(MethodCall _){
    onFileChange();
  }

  void _startFileMonitor() async {
    if (RuntimePlatform.isAndroid) {
      mCMan.methodChannel.invokeListMethod(
          'log.core.startWatching', {"filePath": widget.filePath});
      mCMan.addHandler('onFileChange', handleFileChange);
    } else if (RuntimePlatform.isLinux) {
      _logFile.watch().listen((e) {
        onFileChange();
      });
    } else {
      // if os does not support file monitoring, e.g. windows and mac do not monitor appending
      _timer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
        onFileChange();
      });
    }
  }

  void _scrollToBottom() {
    // _scrollController.animateTo(
    //   _scrollController.position.maxScrollExtent,
    //   duration: const Duration(milliseconds: 200),
    //   curve: Curves.easeOut,
    // );
    if (!_scrollController.hasClients) {
      return;
    }
    _scrollController.jumpTo(
      _scrollController.position.minScrollExtent,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
        padding: const EdgeInsets.all(8.0),
        child: Align(
            child: SelectionArea(
          child: ListView.builder(
            reverse: true,
            controller: _scrollController,
            itemCount: _logLines.length,
            itemBuilder: (context, index) {
              return colorizeLogLine(_logLines[_logLines.length - 1 - index]);
            },
            physics: const ClampingScrollPhysics(),
            cacheExtent: 99999,
          ),
        )));
  }
}

Widget colorizeLogLine(String logline) {
  // Regular expression to capture datetime, protocol, IP, ports, and other parts.
  final RegExp regex = RegExp(
      r'(\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{6})?)(?: from)? ([^\s]+) accepted ([^\s]+) (.*)');
  final match = regex.firstMatch(logline);

  if (match == null) {
    return Text(
        logline); // Return plain text if the line doesn't match the pattern
  }

  // Extract matched groups
  final datetime = match.group(1); // e.g. 2024/09/06 20:48:34
  final address1 = match.group(2); // e.g. tcp:127.0.0.1
  final address2 = match.group(3); // e.g. tcp:alive.github.com
  final extra = match.group(4); // e.g. in_9511 -> ot_lp_bl_29_57_25_cf.vultr

  return RichText(
    text: TextSpan(
      children: [
        TextSpan(
          text: '$datetime ', // DateTime part
          style: const TextStyle(color: Color(0xff90c4f9)),
        ),
        const TextSpan(
          text: 'from ', // Accepted text
          style: TextStyle(color: Colors.grey),
        ),
        TextSpan(
          text: '$address1 ', // First protocol, IP, and port
          style: const TextStyle(color: Color(0xfffb9d51)),
        ),
        const TextSpan(
          text: 'accepted ', // Accepted text
          style: TextStyle(color: Colors.grey),
        ),
        TextSpan(
          text: '$address2 ', // Second protocol, address, and port
          style: const TextStyle(color: Color(0xfffb9d51)),
        ),
        TextSpan(
          text: '[$extra]', // Extra information in brackets
          style: const TextStyle(color: Colors.grey),
        ),
      ],
    ),
  );
}
