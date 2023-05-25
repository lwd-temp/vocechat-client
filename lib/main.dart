import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
// import 'package:firebase_core/firebase_core.dart';
// import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_portal/flutter_portal.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:uni_links/uni_links.dart';
import 'package:vocechat_client/api/lib/user_api.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/dao/org_dao/chat_server.dart';
import 'package:vocechat_client/dao/org_dao/status.dart';
import 'package:vocechat_client/dao/org_dao/userdb.dart';
import 'package:vocechat_client/firebase_options.dart';
import 'package:vocechat_client/services/auth_service.dart';
import 'package:vocechat_client/services/db.dart';
import 'package:vocechat_client/services/sse/sse.dart';
import 'package:vocechat_client/services/status_service.dart';
import 'package:vocechat_client/services/voce_chat_service.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/ui/app_alert_dialog.dart';
import 'package:vocechat_client/ui/app_colors.dart';
import 'package:vocechat_client/ui/auth/chat_server_helper.dart';
import 'package:vocechat_client/ui/auth/login_page.dart';
import 'package:vocechat_client/ui/auth/password_register_page.dart';
import 'package:vocechat_client/ui/chats/chats/chats_main_page.dart';
import 'package:vocechat_client/ui/chats/chats/chats_page.dart';
import 'package:vocechat_client/ui/contact/contacts_page.dart';
import 'package:vocechat_client/ui/settings/settings_page.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _setUpFirebaseNotification();

  App.logger.setLevel(Level.CONFIG, includeCallerInfo: true);

  await initDb();

  Widget defaultHome = ChatsMainPage();

  // await SharedFuncs.readCustomConfigs();

  // Handling login status
  final status = await StatusMDao.dao.getStatus();
  if (status == null) {
    defaultHome = await SharedFuncs.getDefaultHomePage();
  } else {
    final userDb = await UserDbMDao.dao.getUserDbById(status.userDbId);
    if (userDb == null) {
      defaultHome = await SharedFuncs.getDefaultHomePage();
    } else {
      App.app.userDb = userDb;
      await initCurrentDb(App.app.userDb!.dbName);

      if (userDb.loggedIn != 1) {
        Sse.sse.close();
        defaultHome = await SharedFuncs.getDefaultHomePage();
      } else {
        final chatServerM =
            await ChatServerDao.dao.getServerById(userDb.chatServerId);
        if (chatServerM == null) {
          defaultHome = await SharedFuncs.getDefaultHomePage();
        } else {
          App.app.chatServerM = chatServerM;

          // Update server info.
          // Must be done before App.app.chatServerM is initialized.
          // No need await. Will fire new data after data is fetched.
          SharedFuncs.updateServerInfo(App.app.chatServerM, enableFire: true)
              .then((value) {
            if (value != null) {
              App.app.chatServerM = value;
            }
          });

          App.app.statusService = StatusService();
          App.app.authService = AuthService(chatServerM: App.app.chatServerM);

          App.app.chatService = VoceChatService();
        }
      }
    }
  }

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp])
      .then((value) {
    runApp(VoceChatApp(defaultHome: defaultHome));
  });
}

Future<void> _setUpFirebaseNotification() async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging messaging = FirebaseMessaging.instance;
  NotificationSettings settings = await messaging.requestPermission(
    alert: true,
    announcement: false,
    badge: true,
    carPlay: false,
    criticalAlert: false,
    provisional: false,
    sound: true,
  );
  if (settings.authorizationStatus == AuthorizationStatus.authorized) {
    if (kDebugMode) {
      print('User granted permission');
    }
  } else if (settings.authorizationStatus == AuthorizationStatus.provisional) {
    if (kDebugMode) {
      print('User granted provisional permission');
    }
  } else {
    if (kDebugMode) {
      print('User declined or has not accepted permission');
    }
  }
}

// ignore: must_be_immutable
class VoceChatApp extends StatefulWidget {
  VoceChatApp({required this.defaultHome, Key? key}) : super(key: key);

  late Widget defaultHome;

  static _VoceChatAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<_VoceChatAppState>();

  @override
  State<VoceChatApp> createState() => _VoceChatAppState();
}

class _VoceChatAppState extends State<VoceChatApp> with WidgetsBindingObserver {
  late Widget _defaultHome;

  /// Whether the app should fetch new tokens from server.
  ///
  /// When app lifecycle goes through [paused] and [detached], it is set to true.
  /// When app lifecycle goes through [resumed], it is set back to false.
  bool shouldRefresh = false;
  final Connectivity _connectivity = Connectivity();
  late StreamSubscription<ConnectivityResult> _connectivitySubscription;
  Locale? _locale;

  /// When network changes, such as from wi-fi to data, a relay is set to avoid
  /// [_connect()] function to be called repeatly.
  bool _isConnecting = false;

  bool _firstTimeRefreshSinceAppOpens = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _defaultHome = widget.defaultHome;

    _connectivitySubscription =
        _connectivity.onConnectivityChanged.listen(_updateConnectionStatus);

    _initLocale();

    _handleIncomingUniLink();
    _handleInitUniLink();

    _handleInitialNotification();
    _setupForegroundNotification();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription.cancel();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        App.logger.info('App lifecycle: app resumed');

        onResume();

        shouldRefresh = false;

        break;
      case AppLifecycleState.paused:
        App.logger.info('App lifecycle: app paused');

        shouldRefresh = true;

        break;
      case AppLifecycleState.inactive:
        App.logger.info('App lifecycle: app inactive');
        break;
      case AppLifecycleState.detached:
      default:
        App.logger.info('App lifecycle: app detached');

        shouldRefresh = true;

        break;
    }
  }

  void setUILocale(Locale locale) {
    setState(() {
      _locale = locale;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Portal(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        title: 'VoceChat',
        routes: {
          // Auth
          // ServerPage.route: (context) => ServerPage(),
          // LoginPage.route: (context) => LoginPage(),
          // Chats
          ChatsMainPage.route: (context) => ChatsMainPage(),
          ChatsPage.route: (context) => ChatsPage(),
          // Contacts
          ContactsPage.route: (context) => ContactsPage(),
          // ContactDetailPage.route: (context) => ContactDetailPage(),
          // Settings
          SettingPage.route: (context) => SettingPage(),
        },
        theme: ThemeData(
            // canvasColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
            splashColor: Colors.transparent,
            highlightColor: AppColors.grey200,
            fontFamily: 'Inter',
            primarySwatch: Colors.blue,
            dividerTheme: DividerThemeData(thickness: 0.5, space: 1),
            textTheme: TextTheme(
                // headline6:
                // Chats tile title, contacts
                // titleSmall: ,
                // titleMedium:
                //     TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                // All AppBar titles
                titleLarge:
                    TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
        // theme: ThemeData.dark(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        locale: _locale,
        supportedLocales: const [
          Locale('en', 'US'), // English, no country code
          Locale('zh', ''),
        ],
        home: _defaultHome,
      ),
    );
  }

  Future<void> _handleInitialNotification() async {
    RemoteMessage? initialMessage =
        await FirebaseMessaging.instance.getInitialMessage();

    if (initialMessage != null) {
      _handleMessage(initialMessage);
    }

    // notification from background, but not terminated state.
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);
  }

  /// Currently do nothing to foreground notifications,
  /// but keep this function for potential future use.
  void _setupForegroundNotification() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print("FCM received: ${message.data}");

      if (kDebugMode) {
        print('Got a message whilst in the foreground!');
        print('Message data: ${message.data}');
      }

      if (message.notification != null) {
        if (kDebugMode) {
          print(
              'Message also contained a notification: ${message.notification?.body}');
        }
      }
    });
  }

  Future<void> _initLocale() async {
    if (App.app.userDb != null) {
      final userDbM = await UserDbMDao.dao.getUserDbById(App.app.userDb!.id);
      final userLanguageTag = userDbM?.userInfo.language;

      if (userLanguageTag != null && userLanguageTag.isNotEmpty) {
        final split = userLanguageTag.split("-");
        String languageTag = "", regionTag = "";
        try {
          languageTag = split[0];
          regionTag = split[2];
        } catch (e) {
          App.logger.warning(e);
        }
        final locale = Locale(languageTag, regionTag);

        setUILocale(locale);
      }
    }
  }

  void _handleMessage(RemoteMessage message) async {
    print(message.data);
  }

  void _showInvalidLinkWarning(BuildContext context) {
    showAppAlert(
        context: context,
        title: AppLocalizations.of(context)!.invalidInvitationLinkWarning,
        content:
            AppLocalizations.of(context)!.invalidInvitationLinkWarningContent,
        actions: [
          AppAlertDialogAction(
              text: AppLocalizations.of(context)!.ok,
              action: (() => Navigator.of(context).pop()))
        ]);
  }

  Future<bool> _validateMagicToken(String url, String magicToken) async {
    try {
      final res = await UserApi(serverUrl: url).checkMagicToken(magicToken);
      return (res.statusCode == 200 && res.data == true);
    } catch (e) {
      App.logger.severe(e);
    }

    return false;
  }

  void _handleIncomingUniLink() async {
    uriLinkStream.listen((Uri? uri) async {
      print(uri);
      if (uri == null) return;
      _parseLink(uri);
    });
  }

  void _handleInitUniLink() async {
    final initialUri = await getInitialUri();
    if (initialUri == null) return;
    _parseLink(initialUri);
  }

  void _parseLink(Uri uri) {
    const String loginRegexStr = r"\/?(?:\w+\/)?login";
    const String joinRegexStr = r"\/?(?:\w+\/)?join";

    final path = uri.path;

    if (RegExp(loginRegexStr).hasMatch(path)) {
      _handleLoginLink(uri);
    } else if (RegExp(joinRegexStr).hasMatch(path)) {
      _handleJoinLink(uri);
    } else {
      App.logger.warning("Unrecongizable invitation link");
    }
  }

  Future<InvitationLinkData?> _prepareInvitationLinkData(Uri uri) async {
    try {
      final magicLink = uri.queryParameters["magic_link"];
      print("magicLinkHost: $magicLink");

      if (magicLink == null || magicLink.isEmpty) return null;
      final magicLinkUri = Uri.parse(magicLink);
      final magicToken = magicLinkUri.queryParameters["magic_token"];

      print("invLinkUri: $magicLinkUri");

      String serverUrl = magicLinkUri.scheme +
          '://' +
          magicLinkUri.host +
          ":" +
          magicLinkUri.port.toString();

      if (serverUrl == "https://privoce.voce.chat" ||
          serverUrl == "https://privoce.voce.chat:443") {
        serverUrl = "https://dev.voce.chat";
      }

      if (magicToken != null && magicToken.isNotEmpty) {
        if (await _validateMagicToken(serverUrl, magicToken)) {
          return InvitationLinkData(
              serverUrl: serverUrl, magicToken: magicToken);
        } else {
          final context = navigatorKey.currentContext;
          if (context == null) return null;
          _showInvalidLinkWarning(context);
        }
      }
    } catch (e) {
      App.logger.severe(e);
    }

    return null;
  }

  void _handleJoinLink(Uri uri) async {
    print("handleJoinLink");
    final data = await _prepareInvitationLinkData(uri);
    final context = navigatorKey.currentContext;
    print("data: $data, context: $context");
    if (data == null || context == null) return;
    try {
      final chatServer = await ChatServerHelper()
          .prepareChatServerM(data.serverUrl, showAlert: false);
      print("chatServer: $chatServer");
      if (chatServer == null) return;

      final route = PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            PasswordRegisterPage(
                chatServer: chatServer, magicToken: data.magicToken),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0.0, 1.0);
          const end = Offset.zero;
          const curve = Curves.fastOutSlowIn;

          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));

          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      );

      print("before push");

      Navigator.push(context, route);
    } catch (e) {
      App.logger.severe(e);
    }
  }

  void _handleLoginLink(Uri uri) async {
    final serverUrl = uri.queryParameters["s"];

    final context = navigatorKey.currentContext;
    if (serverUrl == null || serverUrl.isEmpty || context == null) return;
    try {
      final chatServer = await ChatServerHelper()
          .prepareChatServerM(serverUrl, showAlert: false);
      if (chatServer == null) return;

      final route = PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            // PasswordRegisterPage(
            //     chatServer: chatServer, magicToken: data.magicToken),
            LoginPage(baseUrl: serverUrl),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0.0, 1.0);
          const end = Offset.zero;
          const curve = Curves.fastOutSlowIn;

          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));

          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      );

      Navigator.push(context, route);
    } catch (e) {
      App.logger.severe(e);
    }
  }

  void onResume() async {
    try {
      if (App.app.authService == null) {
        return;
      }

      // if pre is inactive, do nothing.
      if (!shouldRefresh) {
        return;
      }

      await _connect();
    } catch (e) {
      App.logger.severe(e);
      if (App.app.authService == null) {
        return;
      }

      App.app.authService!.logout().then((value) async {
        final defaultHomePage = await SharedFuncs.getDefaultHomePage();
        if (value) {
          navigatorKey.currentState!.pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (context) => defaultHomePage,
              ),
              (route) => false);
        } else {
          navigatorKey.currentState!.pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (context) => defaultHomePage,
              ),
              (route) => false);
        }
      });
    }
  }

  void onPaused() {}

  void onInactive() {}

  Future<void> _updateConnectionStatus(ConnectivityResult result) async {
    App.logger.info("Connectivity: $result");
    if (result == ConnectivityResult.wifi ||
        result == ConnectivityResult.mobile ||
        result == ConnectivityResult.none) {
      await _connect();
    }
  }

  Future<void> _connect() async {
    if (_isConnecting) return;

    _isConnecting = true;

    final status = await StatusMDao.dao.getStatus();
    if (status != null) {
      final userDb = await UserDbMDao.dao.getUserDbById(status.userDbId);
      if (userDb != null) {
        if (App.app.authService != null) {
          if (await SharedFuncs.renewAuthToken(
              forceRefresh: _firstTimeRefreshSinceAppOpens)) {
            _firstTimeRefreshSinceAppOpens = false;
            App.app.chatService.initSse();
          } else {
            Sse.sse.close();
          }
        }
      }
    }

    _isConnecting = false;
    return;
  }
}

class InvitationLinkData {
  String serverUrl;
  String magicToken;

  InvitationLinkData({required this.serverUrl, required this.magicToken});
}

class UniLinkData {
  String link;
  UniLinkType type;

  UniLinkData({required this.link, required this.type});
}

enum UniLinkType { login, register }
