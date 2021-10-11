import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:pedantic/pedantic.dart';
import 'package:pool/pool.dart';
import 'package:skynet/skynet.dart';
import 'package:collection/collection.dart';
import 'package:alfred/alfred.dart';

import 'package:sentry/sentry.dart';

import 'package:system_resources/system_resources.dart';

final requiredEnvVars = ['ROOT_KEY', 'CHANNELS'];

String rootKey;

const messagesJsonDomain = 'chatbubble.hns';

List<String> allChannelNames;

const retrySeconds = 5;

// TODO bool isLeader = true;

final channelUsers = <String, SkynetUser>{};

final channelPools = <String, Pool>{};

final skynetClient = SkynetClient(
  portal: Platform.environment['PORTAL'] ?? 'siasky.net',
  cookie: Platform.environment['COOKIE'],
);

final ws = SkyDBoverWS(skynetClient);

String serverId;

SkynetUser publicUser;

// TODO Fill bootstrappedMessageIndex[userId] (just use their messages list)

Future<void> main() async {
  await runZonedGuarded(() async {
    if (Platform.environment['SENTRY_DSN'] != null) {
      await Sentry.init(
        (options) {
          options.dsn = Platform.environment['SENTRY_DSN'];
        },
      );
    }

    // Init your App.
    initApp();
  }, (exception, stackTrace) async {
    print(exception);
    print(stackTrace);
    if (Platform.environment['SENTRY_DSN'] != null) {
      await Sentry.captureException(exception, stackTrace: stackTrace);
    }
    exit(1);
  });

/*   int i = 0;

  Stream.periodic(Duration(minutes: 5)).listen((event) {
    i++;
    processMessage(null, {
      "content": {
        "text": "This message is sent every 5 minutes (${DateTime.now()})"
      },
      "channelName": "livestream",
      "index": i,
    });
  }); */
}

void initApp() async {
  final app = Alfred();

  app.get('/status', (req, res) {
    return '''# Resources

CPU Load Average : ${(SystemResources.cpuLoadAvg() * 100).toInt()}%
Memory Usage     : ${(SystemResources.memUsage() * 100).toInt()}%
''';
  });

  // app.all('/api*', (req, res) => _authenticationMiddleware);

  for (final env in requiredEnvVars) {
    if (!Platform.environment.containsKey(env)) {
      throw Exception('Environment variable $env is required');
    }
  }

  rootKey = Platform.environment['ROOT_KEY'];
  allChannelNames = Platform.environment['CHANNELS'].split(',');

  publicUser =
      await SkynetUser.createFromSeedAsync(List.generate(32, (index) => 0));

  for (final channelName in allChannelNames) {
    channelPools[channelName] = Pool(1, timeout: Duration(minutes: 10));
  }
  ws.onConnectionStateChange = () {
    final cs = ws.connectionState;

    String statusHtml;

    if (cs.type == ConnectionStateType.connected) {
      statusHtml = 'Connected with ${ws.endpoint}';
    } else if (cs.type == ConnectionStateType.disconnected) {
      statusHtml = 'Disconnected! Retrying...';
    } else {
      statusHtml = 'None';
    }

    // if (status != null) statusHtml = '$status • $statusHtml';

    // TODO! querySelector('#status').innerHtml = statusHtml;
  };
  ws.connect();

  final rootUser = await SkynetUser.createFromSeedAsync(
    await SkynetUser.skyIdSeedToEd25519Seed(
      rootKey,
    ),
  );

  serverId = rootUser.id;

  logi('');
  logi('SERVER-ID: $serverId');
  logi('');

  final memberListUser = await SkynetUser.createFromSeedAsync(
    await SkynetUser.skyIdSeedToEd25519Seed(
      '$rootKey/userList',
    ),
  );

  app.post('/api/index/update', (req, res) async {
    if (req.headers.value('key') != rootKey) {
      res.statusCode = 401;
      // await res.close();
      return '';
    }
    final body = await req.body; //JSON body

    logi('[index/update] $body');

    final r = await skynetClient.file.getJSONWithRevision(
      rootUser.id,
      'index.json',
    );

    await ws.setJSON(
      rootUser,
      'index.json',
      mergeMaps(r.data, body),
      r.revision + 1,
    );

    logi('[index/update] done');

    return 'ok';
  });

  int customMessageIndex = 0;
  app.post('/api/channel/:channel/send', (req, res) async {
    if (req.headers.value('key') != rootKey) {
      res.statusCode = 401;
      // await res.close();
      return '';
    }
    final Map body = await req.body; //JSON body

    customMessageIndex++;
    processMessage(null, {
      "content": {
        "text": body['text'],
      },
      "channelName": "music",
      "index": customMessageIndex,
    });

    return 'ok';
  });

  await app.listen(8080);

  final rootIndexMap = <String, dynamic>{
    '_self': 'sky://ed25519-${rootUser.id}/index.json',
    'name': 'SkyChat Server',
    'description': 'An awesome SkyChat server',
    'icon': 'sia://AACfm6zdFGhmPau1D-xu8sghAMyyhiQdUQHV4GqAZ-qMOw',
    'owners': [],
    'memberList':
        'sky://ed25519-${memberListUser.id}/social-dac.hns/chatbubble.hns/members.json',
    'channels': {}
  };

  for (final channelName in allChannelNames) {
    final channelUser = await SkynetUser.createFromSeedAsync(
      await SkynetUser.skyIdSeedToEd25519Seed(
        '$rootKey/channel/$channelName',
      ),
    );
    rootIndexMap['channels'][channelName] =
        'sky://ed25519-${channelUser.id}/feed-dac.hns/chatbubble.hns/posts/index.json';

    channelUsers[channelName] = channelUser;
    print('#${channelName}: ${channelUser.id}');
  }

  print(rootIndexMap);

  // return;

  // TODO! querySelector('#output').innerHtml = 'Server ${serverId} logged in.<br>Permission level: Owner<br><br>${JsonEncoder.withIndent('    ').convert(rootIndexMap).replaceAll('\n', '<br>')}';

  final initialMemberListMap = {
    '\$schema':
        'https://skystandards.hns.siasky.net/draft-01/userRelations.schema.json',
    '_self':
        'sky://ed25519-${memberListUser.id}/social-dac.hns/chatbubble.hns/members.json',
    'relationType': 'members',
    'relations': {
      /*  'USERID1': {
        'role': 'owner',
      },
      'USERID2': {
        'role': 'owner',
      }, */
    },
  };

  // ! Setup root index
  final existingRootIndex = await skynetClient.file.getJSONWithRevision(
    rootUser.id,
    'index.json',
  );
  if (existingRootIndex.data == null) {
    print('Setting up root index...');
    await skynetClient.file.setJSON(
      rootUser,
      'index.json',
      rootIndexMap,
      0,
    );
  }

/*   final res = await skynetClient.file.getJSONWithRevision(rootUser.id, 'index.json');

  print('---');
  print(res.revision);
  print(res.data); */

  // ! Setup memberList
  final existingMemberList = await skynetClient.file.getJSONWithRevision(
    memberListUser.id,
    'social-dac.hns/chatbubble.hns/members.json',
  );
  if (existingMemberList.data == null) {
    print('Setting up member list...');
    await skynetClient.file.setJSON(
      memberListUser,
      'social-dac.hns/chatbubble.hns/members.json',
      initialMemberListMap,
      0,
    );
  }

  // ! Setup channels

  final millis = DateTime.now().millisecondsSinceEpoch;

  for (final channel in allChannelNames) {
    print('[check/channel] $channel');

    final res = await skynetClient.file.getJSONWithRevision(
      channelUsers[channel].id,
      'feed-dac.hns/chatbubble.hns/posts/page_0.json',
    );

    if (res.data != null) continue;

    print('[setup/channel] $channel');

    try {
      await skynetClient.file.setJSON(
        channelUsers[channel],
        'profile-dac.hns/profileIndex.json',
        {
          "version": 1,
          "profile": {
            "version": 1,
            "username": "#$channel - SkyChat Server",
            "firstName": "",
            "lastName": "",
            "emailID": "",
            "contact": "",
            "aboutMe": "",
            "location": "",
            "topics": [],
            "connections": [
              {"twitter": ""},
              {"facebook": ""},
              {"github": ""},
              {"reddit": ""},
              {"telegram": ""}
            ],
            "avatar": [
              {
                "ext": "png",
                "w": 240,
                "h": 240,
                "url": "sia:AACfm6zdFGhmPau1D-xu8sghAMyyhiQdUQHV4GqAZ-qMOw"
              }
            ]
          },
          "lastUpdatedBy": "skyprofile.hns",
          "historyLog": [
            {
              "updatedBy": "skyprofile.hns",
              "timestamp": "2021-05-21T18:12:14.882Z"
            }
          ]
        },
        1,
      );
    } catch (e, st) {
      loge(e);
      logv(st);
    }

    try {
      await skynetClient.file.setJSON(
        channelUsers[channel],
        'feed-dac.hns/skapps.json',
        {
          "chatbubble.hns": true,
        },
        1,
      );
      logi('skapps.json ok');
    } catch (e, st) {
      loge(e);
      logv(st);
    }

    try {
      await skynetClient.file.setJSON(
        channelUsers[channel],
        'feed-dac.hns/chatbubble.hns/posts/index.json',
        {
          "version": 1,
          "currPageNumber": 0,
          "currPageNumEntries": 1,
          "pageSize": 64,
          "latestItemTimestamp": millis,
        },
        1,
      );
      print('index.json ok');
    } catch (e, st) {
      loge(e);
      logv(st);
    }
    try {
      await skynetClient.file.setJSON(
        channelUsers[channel],
        'feed-dac.hns/chatbubble.hns/posts/page_0.json',
        {
          "\$schema":
              "https://skystandards.hns.siasky.net/draft-01/feedPage.schema.json",
          "_self":
              "sky://ed25519-${channelUsers[channel].id}/feed-dac.hns/chatbubble.hns/posts/page_0.json",
          "indexPath": "/feed-dac.hns/chatbubble.hns/posts/index.json",
          "items": [
            {
              "id": 0,
              "content": {
                "ext": {
                  "chatbubble.hns": {
                    'userId':
                        null, // TODO Maybe use userId of channel or server (!!! insecure)
                    'serverId': rootUser.id,
                    'channelName': channel,
                    // TODO Matrix extension?
                  },
                },
                "text": "Channel created.",
                "textContentType": "text/plain",
              },
              "ts": millis
            },
          ],
        },
        1,
      );
      print('done with channel $channel');
    } catch (e, st) {
      loge(e);
      logv(st);
    }
  }

  // TODO This adds a user to the member list

/*   await addMemberToServer(
    memberListUser,
    '',
  ); */

  // ! Load everything

/*   final res = await skynetClient.file.getJSON(rootUser.id, 'index.json');

  print(res); */
  Future.delayed(Duration(seconds: 30)).then((value) {
    thisIsTrueAfter30Seconds = true;
    logi('pre-listening completed');
  });

  await syncMemberList(memberListUser);

  updateHtmlMemberList();
  final memberJoinRequestPool = Pool(1, timeout: Duration(minutes: 10));

  ws
      .subscribe(publicUser, '',
          path: 'chatbubble.hns/$serverId/join.request.json')
      .listen((srv) async {
    try {
      logi('[request/join]');
      final res = await ws.downloadFileFromRegistryEntry(srv);

      logi('[request/join] > ${res.asString}');

      // print(res.asString);

      final userList =
          (json.decode(res.asString)['_data'] as List).cast<String>();

      if (userList.isEmpty) {
        return;
      }
      memberJoinRequestPool.withResource(
          () => processNewMemberJoinRequests(userList, memberListUser));
    } catch (e, st) {
      logw('[request/join] $e $st');
    }
    // print(srv);
  });

  print(memberMap.keys);
}

Future processNewMemberJoinRequests(
    List<String> userList, SkynetUser memberListUser) async {
  final usersToAdd = <String>[];
  for (final userId in userList) {
    if (!memberMap.containsKey(userId)) {
      usersToAdd.add(userId);
    }
  }
  logi('[usersToAdd] ${usersToAdd.length} new users ($usersToAdd)');
  await addMemberToServer(
    memberListUser,
    usersToAdd,
  );
  await syncMemberList(memberListUser, skipSync: true);
  updateHtmlMemberList();
  await cleanMemberJoinRequestList(userList);
}

Future<void> cleanMemberJoinRequestList(List<String> userList) async {
  // TODO Add userId validation

  logv('[cleanMemberJoinRequestList] $userList');
  final res = await skynetClient.file.getJSONWithRevision(
    publicUser.id,
    'chatbubble.hns/$serverId/join.request.json',
  );

  /*  print(res.data);
  print(res.revision); */
  for (final userId in userList) {
    (res.data as List).remove(userId);
  }
  await ws.setJSON(
    publicUser,
    'chatbubble.hns/$serverId/join.request.json',
    res.data,
    res.revision + 1,
  );
}

void updateHtmlMemberList() {
  var str = '<ul>';

  for (final userId in memberMap.keys) {
    str += '<li>${memberMap[userId]} $userId</li>';
  }

  // TODO! querySelector('#memberList').innerHtml = str + '</ul>';
}

Map<String, dynamic> memberMap = {};

Future<void> syncMemberList(
  SkynetUser memberListUser, {
  bool skipSync = false,
}) async {
  if (!skipSync) {
    logv('[syncMemberList]');
    final response = await skynetClient.file.getJSON(
      memberListUser.id,
      'social-dac.hns/chatbubble.hns/members.json',
    );

    print(response);

    if (response == null) {
      throw 'could not load member list';
    }

    memberMap = response['relations'];
  }

  for (final userId in memberMap.keys) {
    if (!ws.isSubscribed(SkynetUser.fromId(userId),
        '$messagesJsonDomain/$serverId/messages.json')) {
      /* final temporaryEntryUntilOfficalWebSocketEndpointIsAvailable =
          await getEntry(
        SkynetUser.fromId(userId),
        '',
        hashedDatakey: hex.encode(
          deriveDiscoverableTweak('chatbubble.hns/$serverId/messages.json'),
        ),
      ); */

      logv('[sub] $userId');
      ws
          .subscribe(SkynetUser.fromId(userId), '',
              path: '$messagesJsonDomain/$serverId/messages.json')
          .listen((srv) async {
        try {
          logv('[update] $userId');

          final res = await ws.downloadFileFromRegistryEntry(srv);
          logv('[update/res] $userId ${res.asString}');

          // print(res.asString);

          final List messages = json.decode(res.asString)['_data']['messages'];

          if (!bootstrappedMessageIndex.containsKey(userId)) {
            final int lastIndex = (messages.lastOrNull ?? {})['index'] ?? 0;
            if (!thisIsTrueAfter30Seconds /* lastIndex > 1 */) {
              bootstrappedMessageIndex[userId] = lastIndex;
            } else {
              bootstrappedMessageIndex[userId] = null;
            }
          }

          for (final message in messages) {
            processMessage(userId, message);
          }
        } catch (e, st) {
          logw('[$userId] $e $st');
        }
        // print(srv);
      });
    }
  }
}

bool thisIsTrueAfter30Seconds = false;

final queue = <String, Map>{};
final bootstrappedMessageIndex = <String, int>{};

void processMessage(String userId, Map message) {
  if (message['content']['text'].toString().length > 30000) {
    throw 'Message too long';
  }

  if (!allChannelNames.contains(message['channelName'].toString())) {
    throw 'Channel does not exist';
  }

  if (message['index'] is! int) {
    throw 'index is not an int';
  }
  if (message['index'] < 0) {
    throw 'index below 0';
  }

  if ((bootstrappedMessageIndex[userId] ?? -1) >= message['index']) {
    logv('skipping message because already bootstrapped');
    return;
  }
  final key = '$userId/${message['index']}';

  if (queue.containsKey(key)) {
    logv('skipping message because already in queue');
    return;
  }

  final data = {
    // "id": 0,
    "content": {
      "ext": {
        "chatbubble.hns": {
          'userId': userId,
          'serverId': serverId,
          'channelName': message['channelName'],
          'i': message['index'],
          // TODO Matrix extension?
        },
      },
      "text": message['content']['text'],
      "textContentType": "text/plain",
    },
    "ts": DateTime.now().millisecondsSinceEpoch,
  };
  queue[key] = data;
  final channelName = message['channelName'];
  channelPools[channelName].withResource(
    () => triggerSendingForChannel(channelName),
  );
  // sendAllMessagesInQueue();
}

Future<void> sendAllMessagesInQueue() async {
  try {
    for (final channelName in allChannelNames) {
      unawaited(
        channelPools[channelName].withResource(
          () => triggerSendingForChannel(channelName),
        ),
      );
    }
  } catch (e, st) {
    logw('[sendAllMessagesInQueue] $e $st');
  }
}

Future<void> triggerSendingForChannel(String channelName) async {
  try {
    logi('[channel/send #$channelName] trigger');
    final keysToProcess = [];

    for (final key in queue.keys) {
      if (queue[key] == null) {
        continue;
      }
      if (queue[key]["content"]["ext"]["chatbubble.hns"]['channelName'] ==
          channelName) {
        keysToProcess.add(key);
      }
    }

    if (keysToProcess.isEmpty) {
      logi('[channel/send #$channelName] no messages, returning');
      return;
    }

    keysToProcess.sort((a, b) => queue[a]['ts'].compareTo(queue[b]['ts']));

    logi('[channel/send #$channelName] ${keysToProcess.length} new messages');

    /*  await skynetClient.file.setJSON(
      channelUsers[channel],
      'feed-dac.hns/chatbubble.hns/posts/page_0.json',
      
      1,
    ); */

    final indexRes = await skynetClient.file.getJSONWithRevision(
      channelUsers[channelName].id,
      'feed-dac.hns/chatbubble.hns/posts/index.json',
    );

    final indexData = indexRes.data;

    int currPageNumber = indexData['currPageNumber'];
    final int currPageNumEntries = indexData['currPageNumEntries'];

    Map currentPage;
    int currentPageRevision;

    if ((currPageNumEntries + keysToProcess.length) > 64) {
      currPageNumber++;
      currentPage = {
        "\$schema":
            "https://skystandards.hns.siasky.net/draft-01/feedPage.schema.json",
        "_self":
            "sky://ed25519-${channelUsers[channelName].id}/feed-dac.hns/chatbubble.hns/posts/page_$currPageNumber.json",
        "indexPath": "/feed-dac.hns/chatbubble.hns/posts/index.json",
        "items": [],
      };
      currentPageRevision = 0;
    } else {
      final pageRes = await skynetClient.file.getJSONWithRevision(
        channelUsers[channelName].id,
        'feed-dac.hns/chatbubble.hns/posts/page_$currPageNumber.json',
      );
      currentPage = pageRes.data;
      currentPageRevision = pageRes.revision;
    }

    for (final key in keysToProcess) {
      final item = queue[key];
      item['id'] = currentPage['items'].length;
      currentPage['items'].add(item);
    }

    /*  print(res.data);
    print(res.revision); */

    indexData['currPageNumber'] = currPageNumber;
    indexData['currPageNumEntries'] = currentPage['items'].length;
    indexData['latestItemTimestamp'] = currentPage['items'].last['ts'];

    await skynetClient.file.setJSON(
      channelUsers[channelName],
      'feed-dac.hns/chatbubble.hns/posts/page_$currPageNumber.json',
      currentPage,
      currentPageRevision + 1,
    );

    await ws.setJSON(
      channelUsers[channelName],
      'feed-dac.hns/chatbubble.hns/posts/index.json',
      indexData,
      indexRes.revision + 1,
    );

    for (final key in keysToProcess) {
      queue[key] = null;
    }
    logi('[channel/send #$channelName] done.');
  } on Exception catch (e, st) {
    loge('[channel/send #$channelName] $e');
    logv('[channel/send #$channelName] $st');

    Future.delayed(Duration(seconds: retrySeconds)).then((_) {
      channelPools[channelName].withResource(
        () => triggerSendingForChannel(channelName),
      );
    });
  }
}

Future<void> addMemberToServer(
    SkynetUser memberListUser, List<String> userIds) async {
  // TODO Add userId validation

  logi('[addMemberToServer] $userIds');
  final res = await skynetClient.file.getJSONWithRevision(
    memberListUser.id,
    'social-dac.hns/chatbubble.hns/members.json',
  );

  /*  print(res.data);
  print(res.revision); */
  for (final userId in userIds) {
    res.data['relations'][userId] = {/* 'role': 'owner' */};
  }

  memberMap = res.data['relations'];

  await ws.setJSON(
    memberListUser,
    'social-dac.hns/chatbubble.hns/members.json',
    res.data,
    res.revision + 1,
  );
}

void logv(dynamic line) {
  print('[v] $line');
}

void logw(String line) {
  print('[WARN] $line');
}

void loge(String line) {
  print('[ERROR] $line');
}

void logi(String line) {
  print('[i] $line');
}
