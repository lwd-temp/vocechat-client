// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/dao/init_dao/dm_info.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/event_bus_objects/user_change_event.dart';
import 'package:vocechat_client/globals.dart';
import 'package:vocechat_client/models/ui_models/chat_page_controller.dart';
import 'package:vocechat_client/models/ui_models/chat_tile_data.dart';
import 'package:vocechat_client/services/task_queue.dart';
import 'package:vocechat_client/services/voce_chat_service.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/ui/chats/chat/input_field/app_mentions.dart';
import 'package:vocechat_client/ui/chats/chat/voce_chat_page.dart';
import 'package:vocechat_client/ui/chats/chats/chats_bar.dart';
import 'package:vocechat_client/ui/chats/chats/voce_chat_tile.dart';

class ChatsPage extends StatefulWidget {
  static const route = "/chats/chats";

  const ChatsPage({Key? key}) : super(key: key);

  // ignore: library_private_types_in_public_api
  static _ChatsPageState? of(BuildContext context) =>
      context.findAncestorStateOfType<_ChatsPageState>();

  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage>
    with AutomaticKeepAliveClientMixin<ChatsPage> {
  TaskQueue taskQueue = TaskQueue(enableStatusDisplay: true);

  ValueNotifier<int> memberCountNotifier = ValueNotifier(0);

  final Map<String, ChatTileData> chatTileMap = {};

  int count = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    prepareChats();
    getMemberCount();
    calUnreadCountSum();

    App.app.chatService.subscribeMsg(_onMessage);
    App.app.chatService.subscribeGroups(_onChannel);
    App.app.chatService.subscribeUsers(_onUser);
    App.app.chatService.subscribeRefresh(_onRefresh);

    eventBus.on<UserChangeEvent>().listen((event) {
      clearChats();
      prepareChats();
      getMemberCount();

      calUnreadCountSum();

      App.app.chatService.subscribeMsg(_onMessage);
      App.app.chatService.subscribeGroups(_onChannel);
      App.app.chatService.subscribeUsers(_onUser);
      App.app.chatService.subscribeRefresh(_onRefresh);
    });
  }

  @override
  void dispose() {
    clearChats();
    App.app.chatService.unsubscribeMsg(_onMessage);
    App.app.chatService.unsubscribeGroups(_onChannel);
    App.app.chatService.unsubscribeUsers(_onUser);
    App.app.chatService.unsubscribeRefresh(_onRefresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: ChatsBar(
        memberCountNotifier: memberCountNotifier,
        showDrawer: () => Scaffold.of(context).openDrawer(),
        onCreateChannel: (groupInfoM) async {
          final tileData = await ChatTileData.fromChannel(groupInfoM);
          final chatId = SharedFuncs.getChatId(gid: groupInfoM.gid);
          if (chatId != null) {
            chatTileMap.addAll({chatId: tileData});
            onTap(tileData);
          }
        },
        onCreateDm: (userInfoM) async {
          final tileData = await ChatTileData.fromUser(userInfoM);
          final chatId = SharedFuncs.getChatId(uid: userInfoM.uid);
          if (chatId != null) {
            chatTileMap.addAll({chatId: tileData});
            onTap(tileData);
          }
        },
      ),
      body: _buildChats(),
    );
  }

  List<ChatTileData> sortTileData() {
    final List<ChatTileData> pinned = [];
    final List<ChatTileData> unpinned = [];

    for (var tileData in chatTileMap.values) {
      if (tileData.pinnedAt > 0) {
        pinned.add(tileData);
      } else {
        unpinned.add(tileData);
      }
    }

    pinned.sort((a, b) {
      if (a.pinnedAt != b.pinnedAt) {
        return b.pinnedAt - a.pinnedAt;
      } else {
        return b.updatedAt.value - a.updatedAt.value;
      }
    });

    unpinned.sort((a, b) => b.updatedAt.value - a.updatedAt.value);

    return [...pinned] + [...unpinned];
  }

  Widget _buildChats() {
    final chatTileList = sortTileData();

    return ListView.separated(
      itemCount: chatTileList.length,
      itemBuilder: (context, index) {
        return VoceChatTile(
            key: ObjectKey(chatTileList[index]),
            tileData: chatTileList[index],
            onTap: onTap);
      },
      separatorBuilder: (context, index) {
        return const Divider(indent: 80);
      },
    );
  }

  /// [VoceChatService] Message listener
  ///
  /// Only do its work when [afterReady] is true.
  Future<void> _onMessage(ChatMsgM chatMsgM, bool afterReady,
      {bool? snippetOnly}) async {
    if (!afterReady) return;

    final chatId =
        SharedFuncs.getChatId(uid: chatMsgM.dmUid, gid: chatMsgM.gid);
    if (chatId != null && chatTileMap.containsKey(chatId)) {
      await chatTileMap[chatId]?.updateByChatMsg(chatMsgM);
    } else {
      // if no current chat session, create a new one
      final tileData = await ChatTileData.fromChatMsgM(chatMsgM);
      final chatId =
          SharedFuncs.getChatId(uid: chatMsgM.dmUid, gid: chatMsgM.gid);
      if (chatId != null && tileData != null) {
        chatTileMap.addAll({chatId: tileData});
      }

      // Only work when [afterReady] is true.
      await DmInfoDao()
          .addOrUpdate(DmInfoM.item(chatMsgM.dmUid, "", chatMsgM.createdAt));
    }

    calUnreadCountSum();

    if (mounted) {
      setState(() {});
    }
  }

  void _onRefresh() {
    prepareChats();
  }

  Future<void> _onChannel(
      GroupInfoM groupInfoM, EventActions action, bool afterReady) async {
    final chatId = SharedFuncs.getChatId(gid: groupInfoM.gid);

    switch (action) {
      case EventActions.create:
      case EventActions.update:
        if (chatId != null) {
          if (!chatTileMap.containsKey(chatId)) {
            final tileData = await ChatTileData.fromChannel(groupInfoM);
            chatTileMap.addAll({chatId: tileData});
          } else {
            await chatTileMap[chatId]?.setChannel(groupInfoM: groupInfoM);
          }
        }
        break;
      case EventActions.delete:
        if (chatId != null) {
          chatTileMap.remove(chatId);
        }
        break;
      default:
    }

    calUnreadCountSum();
    // if (afterReady) {
    //   setState(() {});
    // }
  }

  Future<void> _onUser(
      UserInfoM userInfoM, EventActions action, bool afterReady) async {
    final chatId = SharedFuncs.getChatId(uid: userInfoM.uid);

    switch (action) {
      case EventActions.create:
      case EventActions.update:
        if (chatId != null) {
          if (!chatTileMap.containsKey(chatId)) {
            final tileData = await ChatTileData.fromUser(userInfoM);
            chatTileMap.addAll({chatId: tileData});
          } else {
            await chatTileMap[chatId]?.setUser(userInfoM: userInfoM);
          }
        }
        break;
      case EventActions.delete:
        if (chatId != null) {
          chatTileMap.remove(chatId);
        }
        break;
      default:
    }

    calUnreadCountSum();
    // if (afterReady) {
    //   setState(() {});
    // }
  }

  void clearChats() {
    chatTileMap.clear();
  }

  Future<void> prepareChats() async {
    await prepareChannels();
    await prepareDms();
    calUnreadCountSum();
    if (mounted) {
      setState(() {});
    }
  }

  void onTapFromGid(int gid) async {
    final chatId = SharedFuncs.getChatId(gid: gid);
    if (chatTileMap.containsKey(chatId)) {
      onTap(chatTileMap[chatId]!);
    } else {
      return;
    }
  }

  void onTap(ChatTileData tileData) async {
    if (tileData.isChannel) {
      GlobalKey<AppMentionsState> mentionsKey = GlobalKey<AppMentionsState>();
      ChatPageController controller =
          ChatPageController.channel(groupInfoMNotifier: tileData.groupInfoM!);
      controller.prepare().then((value) {
        final unreadCount = tileData.unreadCount.value;
        unreadCountSum.value -= unreadCount;
        Navigator.push(
            context,
            MaterialPageRoute<String?>(
                builder: (context) => VoceChatPage.channel(
                    mentionsKey: mentionsKey,
                    controller: controller))).then((value) async {
          final draft = mentionsKey.currentState?.controller?.text.trim();

          GroupInfoDao()
              .updateProperties(tileData.groupInfoM!.value.gid, draft: draft)
              .then((updatedGroupInfoM) {
            tileData.draft.value = draft ?? "";
          });

          calUnreadCountSum();
          controller.dispose();
        });
      });
    } else {
      GlobalKey<AppMentionsState> mentionsKey = GlobalKey<AppMentionsState>();
      ChatPageController controller =
          ChatPageController.user(userInfoMNotifier: tileData.userInfoM!);
      controller.prepare().then((value) {
        final unreadCount = tileData.unreadCount.value;
        unreadCountSum.value -= unreadCount;
        Navigator.push(
            context,
            MaterialPageRoute<String?>(
                builder: (context) => VoceChatPage.user(
                    mentionsKey: mentionsKey,
                    controller: controller))).then((value) async {
          final draft = mentionsKey.currentState?.controller?.text.trim();

          await UserInfoDao()
              .updateProperties(tileData.userInfoM!.value.uid, draft: draft)
              .then((updatedUserInfoM) {
            tileData.draft.value = draft ?? "";
          });

          calUnreadCountSum();
          controller.dispose();
        });
      });
    }
  }

  Future<void> prepareChannels() async {
    final groupList = await GroupInfoDao().getAllGroupList();

    if (groupList != null) {
      for (GroupInfoM groupInfoM in groupList) {
        final channelTileData = await ChatTileData.fromChannel(groupInfoM);
        final chatId = SharedFuncs.getChatId(gid: groupInfoM.gid);

        if (chatId != null) {
          chatTileMap.addAll({chatId: channelTileData});
        }
      }
    }
  }

  Future<void> prepareDms() async {
    final dmList = await DmInfoDao().getDmList();
    if (dmList == null) return;

    for (final dm in dmList) {
      final dmTileData = await ChatTileData.fromUid(dm.dmUid);
      final chatId = SharedFuncs.getChatId(uid: dm.dmUid);
      if (chatId != null && dmTileData != null) {
        chatTileMap.addAll({chatId: dmTileData});
      }
    }
  }

  void getMemberCount() async {
    final memberCount = (await UserInfoDao().getUserList())?.length;
    if (memberCount != null) {
      memberCountNotifier.value = memberCount;
    }
  }

  void calUnreadCountSum() {
    int count = 0;
    for (var element in chatTileMap.values) {
      count += element.unreadCount.value;
    }
    unreadCountSum.value = count;
  }
}
