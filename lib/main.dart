import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'firebase_options.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const int sleepTimerNotificationIntId = 1001;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Firebase: если упадёт - покажем ошибку на экране вместо белого экрана.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 15));
  } catch (e) {
    runApp(StartupErrorApp(message: 'Firebase: $e'));
    return;
  }

  // 2. Уведомления: не критично, ошибка не должна блокировать запуск.
  try {
    tz.initializeTimeZones();

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    // ВАЖНО: без настроек для iOS плагин на iPhone падает с
    // "Null check operator used on a null value" -> белый экран.
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    await flutterLocalNotificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {},
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  } catch (e, st) {
    debugPrint('Notifications init error: $e\n$st');
  }

  runApp(const MyApp());
}

// Экран ошибки запуска (чтобы не было белого экрана без объяснений)
class StartupErrorApp extends StatelessWidget {
  final String message;
  const StartupErrorApp({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: SingleChildScrollView(
                child: Text(
                  'Ошибка запуска:\n$message',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Уведомление таймера сна
Future<void> showSleepTimerNotification(DateTime startTime) async {
  final androidDetails = AndroidNotificationDetails(
    'sleep_timer_channel',
    'Таймер сна',
    channelDescription: 'Показывает, что идёт отслеживание сна',
    importance: Importance.low,
    priority: Priority.low,
    ongoing: true,
    usesChronometer: true,
    chronometerCountDown: false,
    showWhen: true,
    when: startTime.millisecondsSinceEpoch,
    autoCancel: false,
    color: Colors.white,
    onlyAlertOnce: true,
  );

  await flutterLocalNotificationsPlugin.show(
    sleepTimerNotificationIntId,
    'Сон отслеживается',
    'Нажмите, чтобы вернуться в приложение',
    NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(),
    ),
  );
}

Future<void> hideSleepTimerNotification() async {
  await flutterLocalNotificationsPlugin.cancel(sleepTimerNotificationIntId);
}

// ============================================================
// MY APP
// ============================================================
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sleep Tracking',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ru', 'RU'),
        Locale('en', 'US'),
      ],
      locale: const Locale('ru', 'RU'),
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.white,
        fontFamily: 'Roboto',
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white70,
          surface: Colors.black,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

// ============================================================
// AUTH GATE
// ============================================================
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (!snapshot.hasData) return const LoginScreen();

        final uid = snapshot.data!.uid;
        return FutureBuilder<DocumentSnapshot>(
          future: FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .get(),
          builder: (context, userSnapshot) {
            if (userSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                  body: Center(child: CircularProgressIndicator()));
            }
            final data = userSnapshot.data?.data() as Map<String, dynamic>?;
            final hasOnboarding = data?['onboardingCompleted'] == true;
            if (hasOnboarding) {
              return const MainScreen();
            } else {
              return const OnboardingWelcome();
            }
          },
        );
      },
    );
  }
}

// ============================================================
// ЭКРАН ВХОДА
// ============================================================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _isLogin = true;
  bool _obscurePassword = true;

  Future<void> _submit() async {
    if (_emailController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Введите email и пароль'),
            backgroundColor: Colors.red),
      );
      return;
    }
    setState(() => _isLoading = true);
    try {
      if (_isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
      } else {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
      }
    } on FirebaseAuthException catch (e) {
      debugPrint('Auth error: ${e.code} ${e.message}');
      String message = 'Не удалось выполнить вход. Попробуйте ещё раз.';
      switch (e.code) {
        case 'invalid-credential':
        case 'user-not-found':
        case 'wrong-password':
          message = 'Неверный email или пароль';
          break;
        case 'email-already-in-use':
          message = 'Этот email уже занят';
          break;
        case 'weak-password':
          message = 'Пароль минимум 6 символов';
          break;
        case 'invalid-email':
          message = 'Некорректный email';
          break;
        case 'user-disabled':
          message = 'Аккаунт отключён';
          break;
        case 'too-many-requests':
          message = 'Слишком много попыток. Попробуйте позже';
          break;
        case 'network-request-failed':
          message = 'Проблема с интернетом';
          break;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    final resetEmailController = TextEditingController();
    bool isSending = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          title: const Text('Восстановление пароля',
              style: TextStyle(color: Colors.white, fontSize: 18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Введите email, указанный при регистрации. Мы отправим ссылку для сброса пароля.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: resetEmailController,
                keyboardType: TextInputType.emailAddress,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'your@email.com',
                  hintStyle: const TextStyle(color: Colors.white24),
                  prefixIcon: const Icon(Icons.email_outlined,
                      color: Colors.white54),
                  filled: true,
                  fillColor: Colors.white10,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Colors.white12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Colors.white38),
                  ),
                ),
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actions: [
            TextButton(
              onPressed: isSending ? null : () => Navigator.pop(ctx),
              child: const Text('Отмена',
                  style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: isSending
                  ? null
                  : () async {
                      final email = resetEmailController.text.trim();
                      if (email.isEmpty || !email.contains('@')) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            content: Text('Введите корректный email'),
                            backgroundColor: Colors.red,
                          ),
                        );
                        return;
                      }
                      setDialogState(() => isSending = true);
                      try {
                        await FirebaseAuth.instance
                            .sendPasswordResetEmail(email: email);
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'Ссылка для сброса пароля отправлена на $email'),
                              backgroundColor: Colors.green,
                              duration: const Duration(seconds: 4),
                            ),
                          );
                        }
                      } on FirebaseAuthException catch (e) {
                        setDialogState(() => isSending = false);
                        String msg = 'Не удалось отправить письмо';
                        if (e.code == 'user-not-found') {
                          msg = 'Пользователь с таким email не найден';
                        }
                        if (e.code == 'invalid-email') {
                          msg = 'Некорректный email';
                        }
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                                content: Text(msg),
                                backgroundColor: Colors.red),
                          );
                        }
                      }
                    },
              child: isSending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : const Text('Восстановить пароль'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
              image: AssetImage('assets/background_two.png'),
              fit: BoxFit.cover),
        ),
        child: Container(
          color: Colors.black.withValues(alpha: 0.55),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.bedtime,
                        size: 72, color: Colors.white),
                    const SizedBox(height: 12),
                    const Text('Sleep Tracking',
                        style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    const SizedBox(height: 40),
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration('Email', Icons.email),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration(
                        'Пароль',
                        Icons.lock,
                        suffix: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                            color: Colors.white70,
                          ),
                          onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _showForgotPasswordDialog,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Забыли пароль?',
                            style: TextStyle(
                                color: Colors.white54, fontSize: 13)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _isLoading ? null : _submit,
                        child: _isLoading
                            ? const CircularProgressIndicator(
                                color: Colors.black)
                            : Text(
                                _isLogin
                                    ? 'Войти'
                                    : 'Зарегистрироваться',
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600)),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => _isLogin = !_isLogin),
                      child: Text(
                        _isLogin
                            ? 'Нет аккаунта? Зарегистрироваться'
                            : 'Уже есть аккаунт? Войти',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon,
      {Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white70),
      prefixIcon: Icon(icon, color: Colors.white70),
      suffixIcon: suffix,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white54),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white),
      ),
    );
  }
}

// ============================================================
// ОНБОРДИНГ
// ============================================================
class OnboardingWelcome extends StatelessWidget {
  const OnboardingWelcome({super.key});
  @override
  Widget build(BuildContext context) {
    return _onboardingScaffold(
      Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          const Icon(Icons.bedtime, size: 72, color: Colors.white),
          const SizedBox(height: 12),
          const Text('Sleep Tracking',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(height: 8),
          const Text('Спите лучше с трекером сна',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.white70)),
          const SizedBox(height: 40),
          _whiteButton('Начало', () {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const OnboardingGoals()));
          }),
        ],
      ),
    );
  }
}

class OnboardingGoals extends StatefulWidget {
  const OnboardingGoals({super.key});
  @override
  State<OnboardingGoals> createState() => _OnboardingGoalsState();
}

class _OnboardingGoalsState extends State<OnboardingGoals> {
  final Set<String> _selected = {};
  final _goals = const [
    'Узнать особенности моего сна',
    'Быстрее засыпать',
    'Улучшить качество сна',
    'Легче вставать по утрам',
    'Отрегулировать ритм жизни',
    'Расслабиться',
  ];

  @override
  Widget build(BuildContext context) {
    return _onboardingScaffold(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          const Text('Что вы хотите от нашего приложения?',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(height: 8),
          const Text('Можно выбрать несколько',
              style: TextStyle(fontSize: 14, color: Colors.white54)),
          const SizedBox(height: 24),
          Expanded(
            child: ListView.separated(
              itemCount: _goals.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final goal = _goals[i];
                final isSelected = _selected.contains(goal);
                return _optionTile(goal, isSelected, () {
                  setState(() {
                    if (isSelected) {
                      _selected.remove(goal);
                    } else {
                      _selected.add(goal);
                    }
                  });
                });
              },
            ),
          ),
          _whiteButton(
            'Далее',
            _selected.isEmpty
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => OnboardingSleepTime(
                            goals: _selected.toList()),
                      ),
                    ),
          ),
        ],
      ),
    );
  }
}

class OnboardingSleepTime extends StatefulWidget {
  final List<String> goals;
  const OnboardingSleepTime({super.key, required this.goals});
  @override
  State<OnboardingSleepTime> createState() =>
      _OnboardingSleepTimeState();
}

class _OnboardingSleepTimeState extends State<OnboardingSleepTime> {
  String? _selected;
  final _options = const [
    'Меньше 30 мин.',
    'От 30 до 60 мин.',
    'Более 60 мин'
  ];

  @override
  Widget build(BuildContext context) {
    return _onboardingScaffold(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          const Text('Как долго вы в среднем засыпаете?',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(height: 30),
          ..._options.map((option) {
            final selected = _selected == option;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _optionTile(option, selected,
                  () => setState(() => _selected = option)),
            );
          }),
          const Spacer(),
          _whiteButton(
            'Далее',
            _selected == null
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => OnboardingGenderAge(
                            goals: widget.goals,
                            sleepTime: _selected!),
                      ),
                    ),
          ),
        ],
      ),
    );
  }
}

class OnboardingGenderAge extends StatefulWidget {
  final List<String> goals;
  final String sleepTime;
  const OnboardingGenderAge(
      {super.key, required this.goals, required this.sleepTime});
  @override
  State<OnboardingGenderAge> createState() =>
      _OnboardingGenderAgeState();
}

class _OnboardingGenderAgeState extends State<OnboardingGenderAge> {
  String? _gender;
  int _age = 18;

  @override
  Widget build(BuildContext context) {
    return _onboardingScaffold(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          const Text('Мы можем узнать о вас больше?',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(height: 30),
          Row(
            children: [
              Expanded(
                  child: _optionTile(
                      'Мужской',
                      _gender == 'Мужской',
                      () => setState(() => _gender = 'Мужской'))),
              const SizedBox(width: 12),
              Expanded(
                  child: _optionTile(
                      'Женский',
                      _gender == 'Женский',
                      () => setState(() => _gender = 'Женский'))),
            ],
          ),
          const SizedBox(height: 20),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _gender = null),
              child: const Text('○ Предпочитаю не сообщать',
                  style: TextStyle(color: Colors.white70)),
            ),
          ),
          const SizedBox(height: 30),
          const Text('Возраст',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, color: Colors.white)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: () =>
                    setState(() => _age = (_age - 1).clamp(10, 100)),
                icon: const Icon(Icons.chevron_left,
                    color: Colors.white),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white54),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('$_age',
                    style: const TextStyle(
                        fontSize: 36,
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
              ),
              IconButton(
                onPressed: () =>
                    setState(() => _age = (_age + 1).clamp(10, 100)),
                icon: const Icon(Icons.chevron_right,
                    color: Colors.white),
              ),
            ],
          ),
          const Spacer(),
          _whiteButton(
            'Далее',
            () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => OnboardingBedTime(
                        goals: widget.goals,
                        sleepTime: widget.sleepTime,
                        gender: _gender ?? 'Не указан',
                        age: _age))),
          ),
        ],
      ),
    );
  }
}

class OnboardingBedTime extends StatefulWidget {
  final List<String> goals;
  final String sleepTime;
  final String gender;
  final int age;
  const OnboardingBedTime({
    super.key,
    required this.goals,
    required this.sleepTime,
    required this.gender,
    required this.age,
  });
  @override
  State<OnboardingBedTime> createState() =>
      _OnboardingBedTimeState();
}

class _OnboardingBedTimeState extends State<OnboardingBedTime> {
  TimeOfDay _time = const TimeOfDay(hour: 22, minute: 0);
  bool _saving = false;

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
                primary: Colors.white, onPrimary: Colors.black)),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .set({
        'goals': widget.goals,
        'sleepTime': widget.sleepTime,
        'gender': widget.gender,
        'age': widget.age,
        'bedTime':
            '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
        'onboardingCompleted': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
                builder: (_) => const MainScreen()),
            (route) => false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_friendlyError(e)),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeStr =
        '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';
    return _onboardingScaffold(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          const Text('В котором часу вы обычно ложитесь спать?',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const Spacer(),
          Center(
            child: GestureDetector(
              onTap: _pickTime,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 40, vertical: 24),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white54),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(timeStr,
                    style: const TextStyle(
                        fontSize: 56,
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ),
          const Spacer(),
          _whiteButton('Далее', _saving ? null : _save,
              loading: _saving),
        ],
      ),
    );
  }
}

// ============================================================
// ВСПОМОГАТЕЛЬНЫЕ ВИДЖЕТЫ ОНБОРДИНГА
// ============================================================
Widget _onboardingScaffold(Widget child) {
  return Scaffold(
    body: Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
            image: AssetImage('assets/background_one.png'),
            fit: BoxFit.cover),
      ),
      child: Container(
        color: Colors.black.withValues(alpha: 0.55),
        child: SafeArea(
          child: Padding(
              padding: const EdgeInsets.all(24), child: child),
        ),
      ),
    ),
  );
}

Widget _optionTile(String text, bool selected, VoidCallback onTap) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(
          vertical: 18, horizontal: 16),
      decoration: BoxDecoration(
        color: selected ? Colors.white : Colors.transparent,
        border: Border.all(
            color: selected ? Colors.white : Colors.white54,
            width: selected ? 2 : 1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: selected ? Colors.black : Colors.white,
                    fontWeight: selected
                        ? FontWeight.bold
                        : FontWeight.normal)),
          ),
          if (selected)
            const Icon(Icons.check, color: Colors.black, size: 20),
        ],
      ),
    ),
  );
}

Widget _whiteButton(String text, VoidCallback? onPressed,
    {bool loading = false}) {
  return SizedBox(
    height: 52,
    child: ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        disabledBackgroundColor: Colors.white38,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
      onPressed: onPressed,
      child: loading
          ? const CircularProgressIndicator(color: Colors.black)
          : Text(text,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600)),
    ),
  );
}

// ============================================================
// ГЛАВНЫЙ ЭКРАН
// ============================================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _tabs = const [
    SleepRecordTab(),
    GraphsTab(),
    ProfileTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _tabs),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        backgroundColor: Colors.black,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.grey,
        selectedLabelStyle: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 12),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.bedtime), label: 'Сон'),
          BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart), label: 'Графики'),
          BottomNavigationBarItem(
              icon: Icon(Icons.person), label: 'Профиль'),
        ],
      ),
    );
  }
}

// ============================================================
// ВКЛАДКА 1: ЗАПИСЬ СНА
// ============================================================
class SleepRecordTab extends StatefulWidget {
  const SleepRecordTab({super.key});
  @override
  State<SleepRecordTab> createState() => _SleepRecordTabState();
}

class _SleepRecordTabState extends State<SleepRecordTab> {
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final activeRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('active_session')
        .doc('current');

    return Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
            image: AssetImage('assets/background_one.png'),
            fit: BoxFit.cover),
      ),
      child: Container(
        color: Colors.black.withValues(alpha: 0.6),
        child: SafeArea(
          child: StreamBuilder<DocumentSnapshot>(
            stream: activeRef.snapshots(),
            builder: (context, activeSnap) {
              final isActive =
                  activeSnap.hasData && activeSnap.data!.exists;
              final startTime = isActive
                  ? (activeSnap.data!.data()
                      as Map)['startTime'] as Timestamp?
                  : null;

              return Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Icon(Icons.bedtime,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(height: 24),
                    _SleepScoreBlock(userId: user.uid),
                    const Spacer(),
                    Center(child: _SleepChart(userId: user.uid)),
                    const Spacer(),
                    _buildInfoCard(user.uid),
                    const SizedBox(height: 16),
                    if (!isActive)
                      _timerButton(
                        label: 'Начать сон',
                        color: Colors.white,
                        textColor: Colors.black,
                        onPressed: _isProcessing
                            ? null
                            : () => _startSleep(user.uid),
                        loading: _isProcessing,
                        loadingColor: Colors.black,
                      )
                    else
                      Column(
                        children: [
                          _LiveTimerText(
                              startTime: startTime?.toDate()),
                          const SizedBox(height: 12),
                          _timerButton(
                            label: 'Закончить сон',
                            color: Colors.redAccent,
                            textColor: Colors.white,
                            onPressed: _isProcessing
                                ? null
                                : () => _endSleep(
                                    user.uid, startTime),
                            loading: _isProcessing,
                            loadingColor: Colors.white,
                          ),
                        ],
                      ),
                    const SizedBox(height: 10),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard(String userId) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFE0E0E0),
        borderRadius: BorderRadius.circular(8),
      ),
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .collection('sleep_entries')
            .orderBy('date', descending: true)
            .limit(1)
            .snapshots(),
        builder: (context, snapshot) {
          String duration = '—';
          String wokeUp = '—';
          String fellAsleep = '—';

          if (snapshot.hasData &&
              snapshot.data!.docs.isNotEmpty) {
            final data = snapshot.data!.docs.first.data()
                as Map<String, dynamic>;
            final hours = (data['hours'] as num?)?.toDouble() ?? 0;
            duration = '${hours.toStringAsFixed(1)} ч';
            final start =
                (data['startTime'] as Timestamp?)?.toDate();
            final end = (data['endTime'] as Timestamp?)?.toDate();
            if (start != null) fellAsleep = _formatTime(start);
            if (end != null) wokeUp = _formatTime(end);
          }

          return Column(
            children: [
              _infoRow('продолжительность', duration),
              const SizedBox(height: 16),
              _infoRow('проснулся', wokeUp),
              const SizedBox(height: 16),
              _infoRow('заснул в', fellAsleep),
            ],
          );
        },
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      children: [
        Text(label,
            style: const TextStyle(
                color: Colors.black54, fontSize: 15)),
        const SizedBox(width: 8),
        Expanded(
            child: Container(height: 1, color: Colors.black26)),
        const SizedBox(width: 8),
        Text(value,
            style: const TextStyle(
                color: Colors.black87,
                fontSize: 15,
                fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _timerButton({
    required String label,
    required Color color,
    required Color textColor,
    required VoidCallback? onPressed,
    bool loading = false,
    Color loadingColor = Colors.black,
  }) {
    return SizedBox(
      height: 56,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
          disabledBackgroundColor: color.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30)),
        ),
        onPressed: onPressed,
        child: loading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(loadingColor),
                ),
              )
            : Text(label,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Future<void> _startSleep(String userId) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      final now = DateTime.now();
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('active_session')
          .doc('current')
          .set({'startTime': Timestamp.fromDate(now)});

      await showSleepTimerNotification(now);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_friendlyError(e)),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _endSleep(
      String userId, Timestamp? startTime) async {
    if (_isProcessing) return;
    if (startTime == null) return;
    setState(() => _isProcessing = true);

    try {
      final start = startTime.toDate();
      final end = DateTime.now();
      final hours = end.difference(start).inMinutes / 60.0;

      // Слишком короткая сессия - скорее всего нажали случайно
      if (end.difference(start) < const Duration(minutes: 10)) {
        final save = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('Очень короткий сон',
                style: TextStyle(color: Colors.white)),
            content: const Text(
              'Сессия длится меньше 10 минут. Сохранить её в историю?',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Удалить',
                    style: TextStyle(color: Colors.redAccent)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Сохранить',
                    style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        );
        if (save != true) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(userId)
              .collection('active_session')
              .doc('current')
              .delete();
          await hideSleepTimerNotification();
          return;
        }
      }

      String quality;
      if (hours >= 7) {
        quality = 'Отлично';
      } else if (hours >= 5) {
        quality = 'Хорошо';
      } else {
        quality = 'Плохо';
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('sleep_entries')
          .add({
        'startTime': Timestamp.fromDate(start),
        'endTime': Timestamp.fromDate(end),
        'hours': double.parse(hours.toStringAsFixed(2)),
        'quality': quality,
        'date': FieldValue.serverTimestamp(),
      });

      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('active_session')
          .doc('current')
          .delete();

      await hideSleepTimerNotification();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_friendlyError(e)),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }
}

// ============================================================
// БЛОК «ОЦЕНКА СНА»
// ============================================================
class _SleepScoreBlock extends StatelessWidget {
  final String userId;
  const _SleepScoreBlock({required this.userId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('sleep_entries')
          .orderBy('date', descending: true)
          .limit(1)
          .snapshots(),
      builder: (context, snapshot) {
        double hours = 0;
        if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
          final data = snapshot.data!.docs.first.data()
              as Map<String, dynamic>;
          hours = (data['hours'] as num?)?.toDouble() ?? 0;
        }

        final score = (hours / 8.0 * 5.0).clamp(0.0, 5.0);

        Color scoreColor;
        if (score >= 4.5) {
          scoreColor = const Color(0xFF7DD87D);
        } else if (score >= 3.5) {
          scoreColor = const Color(0xFFE8C96A);
        } else if (score >= 2.5) {
          scoreColor = const Color(0xFFE89B6A);
        } else if (score > 0) {
          scoreColor = const Color(0xFFD97A7A);
        } else {
          scoreColor = Colors.white54;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'ОЦЕНКА СНА',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    letterSpacing: 2.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                if (score > 0)
                  Text(
                    score.toStringAsFixed(1),
                    style: TextStyle(
                      color: scoreColor,
                      fontSize: 24,
                      fontWeight: FontWeight.w300,
                      letterSpacing: 1,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF5A2A2A),
                    Color(0xFF7A4A2A),
                    Color(0xFF7A6A2A),
                    Color(0xFF4A7A4A),
                    Color(0xFF5A9A5A),
                  ],
                  stops: [0.0, 0.25, 0.5, 0.75, 1.0],
                ),
              ),
            ),
            if (score > 0)
              Transform.translate(
                offset: const Offset(0, -6),
                child: Align(
                  alignment:
                      Alignment(-1 + (score / 5.0) * 2, 0),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: scoreColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color:
                              scoreColor.withValues(alpha: 0.4),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                Text('1.0',
                    style: TextStyle(
                        color: Colors.white30,
                        fontSize: 10,
                        letterSpacing: 1)),
                Text('5.0',
                    style: TextStyle(
                        color: Colors.white30,
                        fontSize: 10,
                        letterSpacing: 1)),
              ],
            ),
          ],
        );
      },
    );
  }
}

// ============================================================
// ЖИВОЙ ТАЙМЕР
// ============================================================
class _LiveTimerText extends StatefulWidget {
  final DateTime? startTime;
  const _LiveTimerText({this.startTime});
  @override
  State<_LiveTimerText> createState() => _LiveTimerTextState();
}

class _LiveTimerTextState extends State<_LiveTimerText> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.startTime == null) return const SizedBox.shrink();
    final elapsed = DateTime.now().difference(widget.startTime!);
    final h = elapsed.inHours.toString().padLeft(2, '0');
    final m = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final s = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return Text(
      '$h:$m:$s',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 32,
        fontWeight: FontWeight.w300,
        letterSpacing: 2,
      ),
    );
  }
}

// ============================================================
// КРУГОВОЙ ГРАФИК
// ============================================================
class _SleepChart extends StatelessWidget {
  final String userId;
  const _SleepChart({required this.userId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('sleep_entries')
          .orderBy('date', descending: true)
          .limit(1)
          .snapshots(),
      builder: (context, snapshot) {
        double hours = 0;
        if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
          final data = snapshot.data!.docs.first.data()
              as Map<String, dynamic>;
          hours = (data['hours'] as num?)?.toDouble() ?? 0;
        }

        final progress = (hours / 8.0).clamp(0.0, 1.0);

        Color color;
        if (hours == 0) {
          color = Colors.grey;
        } else if (hours >= 7) {
          color = const Color(0xFF7DD87D);
        } else if (hours >= 5) {
          color = const Color(0xFFE8C96A);
        } else {
          color = const Color(0xFFD97A7A);
        }

        return SizedBox(
          width: 220,
          height: 220,
          child: CustomPaint(
            painter: _SleepRingPainter(
                progress: progress, color: color),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    hours == 0 ? '—' : hours.toStringAsFixed(1),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    hours == 0 ? 'нет данных' : 'часов сна',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SleepRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  _SleepRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 12;

    final bg = Paint()
      ..color = Colors.grey.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bg);

    if (progress > 0) {
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SleepRingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

// ============================================================
// ВКЛАДКА 2: ГРАФИКИ
// ============================================================
class GraphsTab extends StatefulWidget {
  const GraphsTab({super.key});
  @override
  State<GraphsTab> createState() => _GraphsTabState();
}

class _GraphsTabState extends State<GraphsTab> {
  DateTime? _selectedDate;

  String _dateKey(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Query<Map<String, dynamic>> _entriesQuery(String uid) {
    final base = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('sleep_entries')
        .orderBy('date', descending: true);
    final d = _selectedDate;
    if (d == null) return base.limit(100);
    final dayStart = DateTime(d.year, d.month, d.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    return base
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(dayStart))
        .where('date', isLessThan: Timestamp.fromDate(dayEnd));
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      locale: const Locale('ru', 'RU'),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Colors.white,
            onPrimary: Colors.black,
            surface: Color(0xFF1E1E1E),
          ),
          dialogTheme:
              const DialogThemeData(backgroundColor: Color(0xFF1E1E1E)),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  Future<void> _openNoteDialog() async {
    if (_selectedDate == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final dateKey = _dateKey(_selectedDate!);
    final noteRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('notes')
        .doc(dateKey);

    String existingText = '';
    try {
      final snap = await noteRef.get();
      if (snap.exists) {
        existingText = (snap.data()?['text'] as String?) ?? '';
      }
    } catch (_) {}

    if (!mounted) return;

    final controller =
        TextEditingController(text: existingText);

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Text(
            'Заметка на ${_formatDateShort(_selectedDate!)}',
            style: const TextStyle(
                color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 10,
            minLines: 5,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText:
                  'Что произошло в этот день?\nКак спалось? Что снилось?',
              hintStyle: const TextStyle(color: Colors.white24),
              filled: true,
              fillColor: Colors.white10,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: Colors.white12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: Colors.white38),
              ),
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Отмена',
                style: TextStyle(color: Colors.white54)),
          ),
          if (existingText.isNotEmpty)
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, '__DELETE__'),
              child: const Text('Удалить',
                  style: TextStyle(color: Colors.redAccent)),
            ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, controller.text),
            child: const Text('Сохранить',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (action == null) return;

    try {
      if (action == '__DELETE__') {
        await noteRef.delete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
            content: Text('Заметка удалена'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ));
        }
      } else {
        if (action.trim().isEmpty) {
          await noteRef.delete();
        } else {
          await noteRef.set({
            'text': action.trim(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
            content: Text('Заметка сохранена'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_friendlyError(e)),
            backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _deleteEntry(
      BuildContext context, DocumentReference ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Удалить запись?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Запись будет удалена из базы данных без возможности восстановления.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена',
                style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.delete();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
          content: Text('Запись удалена'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_friendlyError(e)),
            backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          _selectedDate == null
              ? 'История снов'
              : _formatDateShort(_selectedDate!),
          style: const TextStyle(fontSize: 18),
        ),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              _selectedDate == null
                  ? Icons.calendar_today_outlined
                  : Icons.calendar_month,
              color: _selectedDate == null
                  ? Colors.white
                  : Colors.white70,
            ),
            tooltip: 'Выбрать дату',
            onPressed: _pickDate,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: _filterChip(
                    label: 'Все сны',
                    selected: _selectedDate == null,
                    onTap: () =>
                        setState(() => _selectedDate = null),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _filterChip(
                    label: _selectedDate == null
                        ? 'По дате'
                        : _formatDateShort(_selectedDate!),
                    selected: _selectedDate != null,
                    onTap: _pickDate,
                  ),
                ),
              ],
            ),
          ),
          if (_selectedDate != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: _NoteButton(
                userId: user.uid,
                dateKey: _dateKey(_selectedDate!),
                onTap: _openNoteDialog,
              ),
            ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _entriesQuery(user.uid).snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState ==
                    ConnectionState.waiting) {
                  return const Center(
                      child: CircularProgressIndicator());
                }
                if (!snapshot.hasData ||
                    snapshot.data!.docs.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Пока нет записей.\nНажмите «Начать сон» на главном экране.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white54, fontSize: 16),
                      ),
                    ),
                  );
                }

                final entries = snapshot.data!.docs;

                if (entries.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment:
                            MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.event_busy,
                              size: 48, color: Colors.white24),
                          const SizedBox(height: 16),
                          Text(
                            'Нет записей за ${_formatDateShort(_selectedDate!)}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 16),
                          ),
                          const SizedBox(height: 16),
                          TextButton(
                            onPressed: () => setState(
                                () => _selectedDate = null),
                            child: const Text(
                                'Показать все сны',
                                style: TextStyle(
                                    color: Colors.white70)),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final data =
                        entries[i].data() as Map<String, dynamic>;
                    final start = (data['startTime']
                            as Timestamp?)
                        ?.toDate();
                    final end =
                        (data['endTime'] as Timestamp?)?.toDate();
                    final hours =
                        (data['hours'] as num?)?.toDouble() ?? 0;
                    final quality = data['quality'] ?? '—';
                    final date =
                        (data['date'] as Timestamp?)?.toDate();

                    Color qualityColor;
                    if (hours >= 7) {
                      qualityColor = const Color(0xFF7DD87D);
                    } else if (hours >= 5) {
                      qualityColor = const Color(0xFFE8C96A);
                    } else {
                      qualityColor = const Color(0xFFD97A7A);
                    }

                    return Card(
                      color: Colors.grey[900],
                      margin:
                          const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(12)),
                      child: Theme(
                        data: Theme.of(context).copyWith(
                            dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          iconColor: Colors.white,
                          collapsedIconColor: Colors.white54,
                          leading: CircleAvatar(
                            backgroundColor: qualityColor
                                .withValues(alpha: 0.2),
                            child: Icon(Icons.bedtime,
                                color: qualityColor, size: 20),
                          ),
                          title: Text(
                            _formatDate(
                                date ?? start ?? DateTime.now()),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16),
                          ),
                          subtitle: Text(
                            '${hours.toStringAsFixed(1)} ч • $quality',
                            style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 13),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.redAccent),
                                tooltip: 'Удалить',
                                onPressed: () => _deleteEntry(
                                    context,
                                    entries[i].reference),
                              ),
                              const Icon(Icons.expand_more,
                                  color: Colors.white54),
                            ],
                          ),
                          children: [
                            Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(
                                      16, 0, 16, 16),
                              child: Column(
                                children: [
                                  _detailRow(
                                      'заснул в',
                                      start != null
                                          ? _formatTime(start)
                                          : '—'),
                                  const SizedBox(height: 8),
                                  _detailRow(
                                      'проснулся',
                                      end != null
                                          ? _formatTime(end)
                                          : '—'),
                                  const SizedBox(height: 8),
                                  _detailRow(
                                      'продолжительность',
                                      '${hours.toStringAsFixed(1)} ч'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          border: Border.all(
              color: selected ? Colors.white : Colors.white24,
              width: 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight:
                selected ? FontWeight.bold : FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(
      children: [
        Text(label,
            style: const TextStyle(
                color: Colors.white54, fontSize: 14)),
        const SizedBox(width: 8),
        Expanded(
            child: Container(height: 1, color: Colors.white24)),
        const SizedBox(width: 8),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold)),
      ],
    );
  }
}

// ============================================================
// КНОПКА «ЗАМЕТКА»
// ============================================================
class _NoteButton extends StatelessWidget {
  final String userId;
  final String dateKey;
  final VoidCallback onTap;

  const _NoteButton({
    required this.userId,
    required this.dateKey,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('notes')
          .doc(dateKey)
          .snapshots(),
      builder: (context, snapshot) {
        final hasNote = snapshot.hasData &&
            snapshot.data!.exists &&
            ((snapshot.data!.data() as Map?)?['text']
                        as String? ??
                    '')
                .isNotEmpty;

        return SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: Icon(
              hasNote
                  ? Icons.sticky_note_2
                  : Icons.note_add_outlined,
              color: hasNote ? Colors.white : Colors.white70,
              size: 20,
            ),
            label: Text(
              hasNote ? 'Открыть заметку' : 'Добавить заметку',
              style: TextStyle(
                color: hasNote ? Colors.white : Colors.white70,
                fontWeight:
                    hasNote ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                  color:
                      hasNote ? Colors.white38 : Colors.white24),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding:
                  const EdgeInsets.symmetric(vertical: 12),
              backgroundColor: hasNote
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.transparent,
            ),
            onPressed: onTap,
          ),
        );
      },
    );
  }
}

// ============================================================
// ВКЛАДКА 3: ПРОФИЛЬ
// ============================================================
class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  Future<void> _signOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Выйти из аккаунта?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Вы вернётесь на экран входа. Данные сохранятся в облаке.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена',
                style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Выйти',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true)
            .pushAndRemoveUntil(
          MaterialPageRoute(
              builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
      await hideSleepTimerNotification();
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_friendlyError(e)),
            backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null) return;

    final passwordController = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Удалить аккаунт?',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Все ваши записи сна и заметки будут удалены безвозвратно. '
              'Для подтверждения введите пароль.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Пароль',
                hintStyle: TextStyle(color: Colors.white38),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white38)),
                focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена',
                style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, passwordController.text),
            child: const Text('Удалить',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    passwordController.dispose();

    if (password == null || password.isEmpty) return;
    if (!context.mounted) return;

    var spinnerShown = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    void closeSpinner() {
      if (spinnerShown && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      spinnerShown = false;
    }

    try {
      final credential = EmailAuthProvider.credential(
          email: user.email!, password: password);
      await user.reauthenticateWithCredential(credential);

      final userDoc =
          FirebaseFirestore.instance.collection('users').doc(user.uid);
      await _deleteCollection(userDoc.collection('sleep_entries'));
      await _deleteCollection(userDoc.collection('notes'));
      await _deleteCollection(userDoc.collection('active_session'));
      await userDoc.delete();

      await hideSleepTimerNotification();
      await user.delete();

      closeSpinner();
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
    } on FirebaseAuthException catch (e) {
      closeSpinner();
      debugPrint('Delete account error: ${e.code} ${e.message}');
      final wrongPassword = e.code == 'wrong-password' ||
          e.code == 'invalid-credential';
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(wrongPassword
              ? 'Неверный пароль'
              : _friendlyError(e)),
          backgroundColor: Colors.red,
        ));
      }
    } catch (e) {
      closeSpinner();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_friendlyError(e)),
            backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Профиль'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.person, size: 80, color: Colors.white54),
            const SizedBox(height: 16),
            Text(user?.email ?? 'Неизвестный пользователь',
                style: const TextStyle(
                    color: Colors.white, fontSize: 18)),
            const SizedBox(height: 40),
            SizedBox(
              width: 200,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => _signOut(context),
                child: const Text('Выйти'),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => _deleteAccount(context),
              child: const Text('Удалить аккаунт',
                  style: TextStyle(color: Colors.redAccent, fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ХЕЛПЕРЫ
// ============================================================
Future<void> _deleteCollection(
    CollectionReference<Map<String, dynamic>> collection) async {
  while (true) {
    final snap = await collection.limit(400).get();
    if (snap.docs.isEmpty) break;
    final batch = FirebaseFirestore.instance.batch();
    for (final d in snap.docs) {
      batch.delete(d.reference);
    }
    await batch.commit();
  }
}

String _friendlyError(Object e) {
  debugPrint('Error: $e');
  if (e is FirebaseException) {
    switch (e.code) {
      case 'permission-denied':
        return 'Нет доступа к данным. Войдите в аккаунт заново';
      case 'unavailable':
      case 'network-request-failed':
        return 'Нет соединения. Проверьте интернет';
      case 'requires-recent-login':
        return 'Войдите в аккаунт заново и повторите действие';
    }
  }
  return 'Что-то пошло не так. Попробуйте ещё раз';
}

String _formatTime(DateTime dt) {
  return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

String _formatDate(DateTime dt) {
  const months = [
    'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
    'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
  ];
  return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
}

String _formatDateShort(DateTime dt) {
  return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
}