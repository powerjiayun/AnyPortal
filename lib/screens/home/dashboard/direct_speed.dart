import 'package:flutter/material.dart';

import '../../../utils/core_data_notifier.dart';
import '../../../utils/format_byte.dart';

class DirectSpeeds extends StatefulWidget {
  const DirectSpeeds({super.key});

  @override
  State<DirectSpeeds> createState() => _DirectSpeedsState();
}

class _DirectSpeedsState extends State<DirectSpeeds> {
  final limitCount = 60;

  @override
  void initState() {
    super.initState();
  }

  Widget keyValueRow(String key, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          key,
        ),
        Text(
          value,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: coreDataNotifier,
      builder: (BuildContext context, Widget? child) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            keyValueRow(
              "↑",
              "${formatBytes(
                  coreDataNotifier.trafficStatCur[TrafficStatType.directUp]!)}ps",
            ),
            keyValueRow(
              "↓",
              "${formatBytes(
                  coreDataNotifier.trafficStatCur[TrafficStatType.directDn]!)}ps",
            ),

          ],
        );
      },
    );
  }

  @override
  void dispose() {
    // timer.cancel();
    super.dispose();
  }
}
