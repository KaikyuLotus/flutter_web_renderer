import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:synchronized/synchronized.dart';
import 'package:window_size/window_size.dart' as window_size;

import 'widgetable.dart';

typedef _JsonMap = Map<String, dynamic>;

typedef WebserverRequestMapping = Map<
    String,
    FutureOr<Widgetable> Function(
  _JsonMap json,
)>;

class WebserverConfig {
  final WebserverRequestMapping requestMapping;
  final Duration renderTimeout;
  final int port;
  final dynamic address;
  final ImageConfiguration imageConfiguration;
  final CacheManager cacheManager;
  final bool autoCompressNetwork;

  WebserverConfig({
    required this.requestMapping,
    this.address = 'localhost',
    this.port = 8080, // InternetAddress.anyIPv4
    this.renderTimeout = const Duration(seconds: 5),
    this.imageConfiguration = const ImageConfiguration(),
    this.autoCompressNetwork = true,
    CacheManager? cacheManager,
  }) : cacheManager = cacheManager ?? DefaultCacheManager();
}

class Webserver {
  final lock = Lock();

  final canvasKey = GlobalKey();

  Future Function(Widgetable?)? stateSetter;

  WebserverConfig config;

  Webserver({required this.config}) {
    var handler = const Pipeline().addHandler(requestHandler);
    shelf_io.serve(handler, config.address, config.port).then((server) {
      server.autoCompress = config.autoCompressNetwork;
      log('Serving at http://${server.address.host}:${server.port}');
    });
  }

  Future<List<CachedNetworkImageProvider>> evaluateImages() async {
    var imageUrls = <CachedNetworkImageProvider>[];

    var completers = <Completer<void>>[];

    ElementVisitor? visitor;
    visitor = (Element element) {
      if (element.widget is Image) {
        var image = element.widget as Image;
        final Completer<void> completer = Completer<void>();
        completers.add(completer);
        image.image
            .resolve(config.imageConfiguration)
            .addListener(ImageStreamListener((ImageInfo info, bool syncCall) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }));
        if (image.image is CachedNetworkImageProvider) {
          var cachedProvider = image.image as CachedNetworkImageProvider;
          imageUrls.add(cachedProvider);
        }
      }
      element.visitChildElements(visitor!);
    };

    canvasKey.currentContext!.visitChildElements(visitor);

    await Future.wait(completers.map((e) => e.future));
    await Future.delayed(const Duration(milliseconds: 200));
    return imageUrls;
  }

  Future<Response> requestHandler(Request request) async {
    return lock.synchronized(
      () async => await _requestHandler(request).timeout(config.renderTimeout),
    );
  }

  Future<Response> _requestHandler(Request request) async {
    var path = request.url.path;

    if (!config.requestMapping.containsKey(path)) {
      return Response.notFound('{"error": "Path not found"}');
    }

    var body = await request.readAsString();
    var jsonMap = json.decode(body);
    var widgetable = await config.requestMapping[path]!(jsonMap);

    var size = widgetable.size;
    window_size.setWindowFrame(Rect.fromLTWH(0, 0, size.width, size.height));

    await stateSetter?.call(widgetable);

    Response? response;

    WidgetsBinding.instance!.addPostFrameCallback((millis) async {
      try {
        await evaluateImages();

        var boundary = canvasKey.currentContext!.findRenderObject()!;
        var image = await (boundary as RenderRepaintBoundary).toImage(
          pixelRatio: widgetable.pixelRatio,
        );
        var byteData = await image.toByteData(format: ImageByteFormat.png);

        response = Response.ok(
          byteData!.buffer.asUint8List(),
          headers: {'Content-Type': 'image/png'},
        );
      } on Exception catch (e, s) {
        log('Cannot get screenshot', error: e, stackTrace: s);
        response = Response.internalServerError(body: '$e\n$s');
      }
    });

    while (response == null) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (kReleaseMode) {
      await stateSetter?.call(null);
    }

    return response!;
  }
}
