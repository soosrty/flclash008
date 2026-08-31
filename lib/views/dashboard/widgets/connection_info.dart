import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';

class ConnectionInfo extends StatefulWidget {
  final Future<int> Function()? connectionCountReader;

  const ConnectionInfo({
    super.key,
    @visibleForTesting this.connectionCountReader,
  });

  @override
  State<ConnectionInfo> createState() => _ConnectionInfoState();
}

class _ConnectionInfoState extends State<ConnectionInfo> {
  final _connectionCountNotifier = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    foregroundTicker.register(this, _updateConnectionCount, fire: true);
  }

  @override
  void dispose() {
    foregroundTicker.unregister(this);
    _connectionCountNotifier.dispose();
    super.dispose();
  }

  Future<void> _updateConnectionCount() async {
    final connectionCountReader = widget.connectionCountReader;
    if (connectionCountReader == null &&
        globalState.container.read(coreStatusProvider) !=
            CoreStatus.connected) {
      return;
    }
    final count = connectionCountReader != null
        ? await connectionCountReader()
        : (await coreController.getConnections()).length;
    if (!mounted) {
      return;
    }
    _connectionCountNotifier.value = count;
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return SizedBox(
      height: getWidgetHeight(1),
      child: RepaintBoundary(
        child: CommonCard(
          onPressed: () {},
          info: Info(
            iconData: Icons.link,
            label: appLocalizations.connectionInfo,
          ),
          child: Container(
            padding: baseInfoEdgeInsets.copyWith(top: 0),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: globalState.measure.bodyMediumHeight + 2,
                  child: ValueListenableBuilder(
                    valueListenable: _connectionCountNotifier,
                    builder: (_, count, _) {
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          Text(
                            '$count',
                            style: context.textTheme.bodyMedium?.toLight
                                .adjustSize(1),
                          ),
                        ],
                      );
                    },
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
