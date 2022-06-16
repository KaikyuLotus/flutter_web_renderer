import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:intl/intl.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:synchronized/synchronized.dart';

import 'window_size_utils.dart';
import 'widgetable.dart';

typedef _JsonMap = Map<String, dynamic>;

typedef WebserverRequestMapping = Map<
    String,
    FutureOr<Widgetable> Function(
  _JsonMap json,
)>;

String _getTime() {
  return DateFormat('kk:mm:ss.SSS').format(DateTime.now());
}

void error(Object? i) {
  stderr.writeln('${_getTime()} - $i');
}

void info(Object? i) {
  stdout.writeln('${_getTime()} - $i');
}

class WebserverConfig {
  final WebserverRequestMapping requestMapping;
  final Duration renderTimeout;
  final int port;
  final dynamic address;
  final ImageConfiguration imageConfiguration;
  final CacheManager cacheManager;
  final bool autoCompressNetwork;
  final bool logRequests;

  WebserverConfig({
    required this.requestMapping,
    this.address = 'localhost',
    this.port = 8080, // InternetAddress.anyIPv4
    this.renderTimeout = const Duration(seconds: 5),
    this.imageConfiguration = const ImageConfiguration(),
    this.autoCompressNetwork = true,
    this.logRequests = false,
    CacheManager? cacheManager,
  }) : cacheManager = cacheManager ?? DefaultCacheManager();
}

class Webserver {
  final lock = Lock();

  final canvasKey = GlobalKey();

  void Function(Widgetable?)? stateSetter;

  WebserverConfig config;

  Webserver({required this.config}) {
    var middleware = createMiddleware(
      errorHandler: onRequestError,
    );
    if (config.logRequests) {
      middleware = middleware.addMiddleware(logRequests(
        logger: (message, isError) {
          (isError ? error : info)(message);
        },
      ));
    }
    final handler = middleware.addHandler(requestHandler);
    shelf_io.serve(handler, config.address, config.port).then((server) {
      server.autoCompress = config.autoCompressNetwork;
      info('Serving at http://${server.address.host}:${server.port}');
    });
  }

  Future<Response> onRequestError(Object error, StackTrace stackTrace) async {
    return Response.internalServerError(
      body: json.encode({
        'error': '$error',
        'st': '$stackTrace',
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<List<CachedNetworkImageProvider>> evaluateImages() async {
    info('Evaluating images');
    final imageUrls = <CachedNetworkImageProvider>[];

    final completers = <Completer<void>>[];

    ElementVisitor? visitor;
    visitor = (Element element) {
      if (element.widget is Image) {
        final image = element.widget as Image;
        final Completer<void> completer = Completer<void>();
        completers.add(completer);
        image.image
            .resolve(config.imageConfiguration)
            .addListener(ImageStreamListener((ImageInfo i, bool syncCall) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }));
        if (image.image is CachedNetworkImageProvider) {
          final cachedProvider = image.image as CachedNetworkImageProvider;
          imageUrls.add(cachedProvider);
        }
      }
      element.visitChildElements(visitor!);
    };

    canvasKey.currentContext!.visitChildElements(visitor);

    await Future.wait(completers.map((e) => e.future));
    await Future.delayed(const Duration(milliseconds: 200));
    info('Done evaluating images');
    return imageUrls;
  }

  Future<Response> requestHandler(Request request) async {
    return lock.synchronized(
      () => _requestHandler(request).timeout(config.renderTimeout),
    );
  }

  Future<Response> _requestHandler(Request request) async {
    final path = request.url.path;

    if (!config.requestMapping.containsKey(path)) {
      return Response.notFound(json.encode({'error': 'Path not found'}));
    }

    info('Handling new request: $path');

    final body = await request.readAsString();
    final jsonMap = json.decode(body);
    final widgetable = await config.requestMapping[path]!(jsonMap);

    final size = widgetable.size;
    info('Setting frame size to $size');
    setWindowFrame(Rect.fromLTWH(0, 0, size.width, size.height));

    info('Calling state setter with the generated widgetable');
    stateSetter?.call(widgetable);

    Response? response;

    WidgetsBinding.instance.addPostFrameCallback((millis) async {
      try {
        // Wait for canvas to be rendered
        while (canvasKey.currentContext == null) {
          await Future.delayed(const Duration(milliseconds: 10));
        }

        await evaluateImages();

        final boundary = canvasKey.currentContext!.findRenderObject()!;
        info(
          'Getting RenderRepaintBoundary as '
          'Image with pixel ratio ${widgetable.pixelRatio}',
        );
        final image = await (boundary as RenderRepaintBoundary).toImage(
          pixelRatio: widgetable.pixelRatio,
        );

        info('Converting image to bytes');
        final byteData = await image.toByteData(format: ImageByteFormat.png);

        response = Response.ok(
          byteData!.buffer.asUint8List(),
          headers: {'Content-Type': 'image/png'},
        );
      } on Exception catch (e, s) {
        response = Response.internalServerError(body: '$e\n$s');
      }
    });

    info('Waiting for frame to be rendered');
    while (response == null) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (kReleaseMode) {
      stateSetter?.call(null);
    }

    info('All done');
    return response!;
  }
}
