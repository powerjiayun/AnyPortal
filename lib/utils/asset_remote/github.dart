// ignore_for_file: use_build_context_synchronously

import 'dart:convert';
import 'dart:core';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import 'package:drift/drift.dart';
import 'package:flutter_socks_proxy/socks_proxy.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;

import '../../models/asset.dart';
import '../db.dart';
import '../global.dart';
import '../logger.dart';
import '../prefs.dart';
import '../show_snack_bar_now.dart';
import '../undmg.dart';
import '../unzip.dart';
import '../vpn_manager.dart';
import '../with_context.dart';

import 'protocol.dart';

class AssetRemoteProtocolGithub implements AssetRemoteProtocol {
  late String url;
  late String protocol = "github";
  late String owner;
  late String repo;
  late String assetName;
  String? subPath;

  AssetRemoteProtocolGithub();

  AssetRemoteProtocolGithub.fromUrl(String url) {
    final regex = RegExp(
      r'^github:\/\/([^\/]+)\/([^\/]+)\/([^\/]+)?(?:\/(.+))?$',
    );

    final match = regex.firstMatch(url);
    if (match != null) {
      this.url = url;
      owner = match.group(1)!;
      repo = match.group(2)!;
      assetName = match.group(3)!;
      subPath = match.group(4); // Nullable
    } else {
      logger.w("match failed: $url");
      withContext((context) {
        showSnackBarNow(context, Text("match failed: $url"));
      });
      throw Exception("match failed: $url");
    }
  }

  Future<String?> getRemoteMeta({bool useSocks = true}) async {
    final metaUrl = "https://api.github.com/repos/$owner/$repo/releases/latest";
    if (useSocks) {
      final httpClient = createProxyHttpClient();
      httpClient.findProxy = (url) =>
          'SOCKS5 ${prefs.getString('app.server.address')!}:${prefs.getInt('app.socks.port')!}';
      final client = IOClient(httpClient);
      final token = prefs.getString('app.github.token');
      final headers = token == null
          ? null
          : {
              'Authorization': 'Bearer $token',
              'X-GitHub-Api-Version': '2022-11-28',
            };
      final response = await client.get(
        Uri.parse(metaUrl),
        headers: headers,
      );
      if (response.statusCode == 200) {
        return response.body;
      } else {
        logger.w(
            "${response.statusCode} when accessing $metaUrl. If using shared ip address/exceeding api limit consider add a github token");
        return null;
      }
    } else {
      final response = await http.get(Uri.parse(metaUrl));
      if (response.statusCode == 200) {
        return response.body;
      } else {
        logger.w(
            "${response.statusCode} when accessing $metaUrl. If using shared ip address/exceeding api limit consider add a github token");
        return null;
      }
    }
  }

  String? getDownloadedMeta({
    TypedResult? asset,
  }) {
    return asset?.read(db.assetRemote.meta);
  }

  bool getIsDownloadedMetaUpdated(
    String? remoteMeta,
    String? downloadedMeta,
  ) {
    if (remoteMeta == null) {
      logger.w("getIsDownloadedMetaUpdated: failed to get remoteMeta");
      return true;
    }

    if (downloadedMeta == null) {
      return false;
    }

    try {
      final downloadedCreatedAt =
          (jsonDecode(downloadedMeta) as Map<String, dynamic>)["created_at"];
      final remoteCreatedAt =
          (jsonDecode(remoteMeta) as Map<String, dynamic>)["created_at"];

      return downloadedCreatedAt == remoteCreatedAt;
    } catch (e) {
      logger.w("getIsDownloadedMetaUpdated: failed to read created_at");
      return false;
    }
  }

  String? getDownloadUrl(String meta) {
    /// getDownloadUrl
    final assetList = (jsonDecode(meta) as Map<String, dynamic>)["assets"];
    for (final asset in assetList) {
      final assetMap = asset as Map<String, dynamic>;
      if (assetMap["name"] == assetName) {
        return assetMap["browser_download_url"];
      }
    }
    return null;
  }

  /// where the freshly downloaded, not yet installed file should be
  File getAssetFile(){
    return File(p.join(global.applicationSupportDirectory.path, 'asset', 'github', owner, repo, assetName));
  }

  Future<File?> download(
    String downloadUrl, {
    bool useSocks = true,
  }) async {
    /// prepare file
    final file = getAssetFile();
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (e) {
        logger.w("failed to delete ${file.path}");
        return null;
      }
    }

    if (useSocks) {
      final client = createProxyHttpClient()
        ..findProxy = (url) =>
            'SOCKS5 ${prefs.getString('app.server.address')!}:${prefs.getInt('app.socks.port')!}';
      final request = await client.getUrl(Uri.parse(downloadUrl));
      final response = await request.close();

      await file.create(recursive: true);
      final sink = file.openWrite();
      await response.pipe(sink);
      sink.close();
      return file;
    } else {
      final client = http.Client();
      final request = http.Request("GET", Uri.parse(downloadUrl));
      final response = await client.send(request);

      await file.create(recursive: true);
      final sink = file.openWrite();
      await response.stream.pipe(sink);
      sink.close();
      return file;
    }
  }

  /// if everythings fine, record to db
  Future<int> postDownload(
    File downloadedFile,
    TypedResult? asset,
    String remoteMeta,
    int autoUpdateInterval,
  ) async {
    String assetPath = downloadedFile.path;
    if (assetPath.toLowerCase().endsWith(".zip") && subPath != null) {
      assetPath = assetPath.substring(0, assetPath.length - 4);
      final subPathList = subPath!.split('/');
      assetPath = File(p.joinAll([assetPath, ...subPathList])).path;
    }
    late int assetId;
    await db.transaction(() async {
      if (asset != null) {
        /// update old asset record
        assetId = asset.read(db.assetRemote.assetId)!;
        await db.into(db.asset).insertOnConflictUpdate(AssetCompanion(
              id: Value(asset.read(db.assetRemote.assetId)!),
              type: const Value(AssetType.remote),
              path: Value(assetPath),
              updatedAt: Value(DateTime.now()),
            ));
      } else {
        /// insert new asset record
        assetId = await db.into(db.asset).insertOnConflictUpdate(AssetCompanion(
              type: const Value(AssetType.remote),
              path: Value(assetPath),
              updatedAt: Value(DateTime.now()),
            ));
      }

      /// update or insert assetRemote record
      await db.into(db.assetRemote).insertOnConflictUpdate(AssetRemoteCompanion(
            assetId: Value(assetId),
            url: Value(url),
            meta: Value(remoteMeta),
            autoUpdateInterval: Value(autoUpdateInterval),
            downloadedFilePath: Value(downloadedFile.path),
          ));
    });

    return assetId;
  }

  /// return installOK
  Future<bool> install(
    File downloadedFile,
  ) async {
    String path = downloadedFile.path;

    bool extractOK = false;
    if (path.toLowerCase().endsWith(".zip")) {
      extractOK = await unzipThere(path);
    } else if (path.toLowerCase().endsWith(".dmg")) {
      extractOK = await undmgThere(path, subPath!);
    }
    if (extractOK) {
      try {
        downloadedFile.delete();
      } catch (e) {
        logger.e("failed to delete $path");
        return false;
      }
      return true;
    }

    return true;
  }

  /// remove downloaded file and path record
  Future<bool> postInstall(int assetId) async {
    /// remove pending install status
    await (db.update(db.assetRemote)..where((e) => e.assetId.equals(assetId)))
        .write(AssetRemoteCompanion(
      assetId: Value(assetId),
      downloadedFilePath: Value(null),
    ));

    return true;
  }

  bool canInstallNow({TypedResult? asset}) {
    if (asset == null) {
      return true;
    }
    final assetPath = asset.read(db.asset.path);
    return !(assetPath == vPNMan.corePath && vPNMan.isCoreActive);
  }

  void loggerD(String text) {
    logger.d(text);
    withContext((context) {
      showSnackBarNow(context, Text(text));
    });
  }

  /// where the downloaded file is, could be null if have installed and then deleted
  String? getDownloadedFilePath({TypedResult? asset}) {
    return asset?.read(db.asset.path);
  }

  /// save last checked timestamp
  Future<void> postGetRemoteMeta(String remoteMeta,
      {TypedResult? asset}) async {
    if (asset == null) return;
    final assetId = asset.read(db.asset.id)!;
    await db.into(db.assetRemote).insertOnConflictUpdate(AssetRemoteCompanion(
          assetId: Value(assetId),
          checkedAt: Value(DateTime.now()),
        ));
  }

  /// return isUpdated
  @override
  Future<bool> update({
    TypedResult? asset,
    int autoUpdateInterval = 0,
  }) async {
    /// check if need to update
    loggerD("to update: $url");
    final downloadedMeta = getDownloadedMeta(asset: asset);
    final remoteMeta = await getRemoteMeta(useSocks: vPNMan.isCoreActive);
    if (remoteMeta == null) {
      loggerD("failed to get meta: $url");
      return true;
    }
    await postGetRemoteMeta(remoteMeta, asset: asset);
    final isDownloadedMetaUpdated =
        getIsDownloadedMetaUpdated(remoteMeta, downloadedMeta);

    int? assetId = asset?.read(db.asset.id);
    String? downloadedFilePath = getDownloadedFilePath(asset: asset);
    File? downloadedFile;
    if (isDownloadedMetaUpdated) {
      /// if meta updated, must have downloaded (could have installed, thus deleted)
      /// check if installed by checking downloadedFilePath
      if (downloadedFilePath != null) {
        loggerD("already downloaded: $url");
        downloadedFile = File(downloadedFilePath);
      } else {
        loggerD("already up to date: $url");
        return true;
      }
    } else {
      /// if meta not updated, need download remote
      /// get download url
      loggerD("need download: $url");
      final downloadUrl = getDownloadUrl(remoteMeta);
      if (downloadUrl == null) {
        loggerD("downloadUrl == null: $url");
        return true;
      }

      /// download
      loggerD("downloading: $downloadUrl");
      downloadedFile = await download(
        downloadUrl,
        useSocks: vPNMan.isCoreActive,
      );
      if (downloadedFile == null) {
        loggerD("download failed: $downloadUrl");
        return false;
      }
      loggerD("downloaded: $downloadUrl");

      /// record remoteMeta after download
      assetId = await postDownload(
        downloadedFile,
        asset,
        remoteMeta,
        autoUpdateInterval,
      );
    }

    if (canInstallNow(asset: asset)) {
      /// install only if not using
      loggerD("installing: $url");
      final installOk = await install(downloadedFile);
      if (installOk) {
        await postInstall(assetId!);
        loggerD("installed: $url");
      } else {
        loggerD("install failed: $url");
      }
    } else {
      loggerD("pending install: $url");
    }
    return true;
  }
}
