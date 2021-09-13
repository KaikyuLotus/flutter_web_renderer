library web_renderer;

import 'package:flutter/material.dart';

import '../web_renderer.dart';

class RenderCanvas extends StatefulWidget {
  final Webserver webserver;

  final ThemeData? theme;

  const RenderCanvas({
    required this.webserver,
    this.theme,
    Key? key,
  }) : super(key: key);

  @override
  State<RenderCanvas> createState() => _RenderCanvasState();
}

class _RenderCanvasState extends State<RenderCanvas> {
  Widgetable? widgetable;

  @override
  void initState() {
    super.initState();

    widget.webserver.stateSetter = (Widgetable? widgetable) async {
      setState(() => this.widgetable = widgetable);
    };
  }

  @override
  Widget build(BuildContext context) {
    if (widgetable == null) {
      return Container();
    }
    return RepaintBoundary(
      key: widget.webserver.canvasKey,
      child: MaterialApp(
        title: 'Renderer',
        theme: widget.theme,
        home: Material(
          type: MaterialType.transparency,
          child: Container(
            color: Colors.transparent,
            child: widgetable!.asWidget(),
          ),
        ),
      ),
    );
  }
}
