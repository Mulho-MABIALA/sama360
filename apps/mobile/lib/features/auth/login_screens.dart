import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'auth_controller.dart';

/// Étape 1 : numéro de téléphone.
class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});
  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final country = ref.read(loginCountryProvider);
    final phone = localPhone(_phone.text, country);
    if (phone == null) {
      final n = country.groups.fold(0, (a, b) => a + b);
      setState(() => _error = 'Numéro invalide : $n chiffres, ex. ${country.example}');
      return;
    }
    final channels = ref.read(otpChannelsProvider).value ?? const [OtpChannel.sms];
    final channel = _channel(channels);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await ref.read(authProvider.notifier).requestOtp(phone, channel: channel);
      if (mounted) {
        context.push('/otp', extra: OtpTarget(sent.phone, channel: sent.channel, channels: channels));
      }
    } on ApiException catch (e) {
      // Un code a déjà été envoyé il y a moins d'une minute : on passe quand même à la saisie.
      if (e.code == 'OTP_TOO_SOON' && mounted) {
        context.push('/otp', extra: OtpTarget(phone, channel: channel, channels: channels));
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Moyens proposés sur cet écran (l'appel vocal reste un recours, sur l'écran du code).
  static List<OtpChannel> _offered(List<OtpChannel> all) {
    final l = all.where((c) => c != OtpChannel.call).toList();
    return l.isEmpty ? all : l;
  }

  /// Moyen choisi : celui retenu sur ce téléphone s'il est proposé, sinon celui du serveur.
  OtpChannel _channel(List<OtpChannel> all) {
    final offered = _offered(all);
    final pref = ref.read(preferredOtpChannelProvider);
    return pref != null && offered.contains(pref) ? pref : offered.first;
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final channels = ref.watch(otpChannelsProvider).value ?? const [OtpChannel.sms];
    ref.watch(preferredOtpChannelProvider);
    final offered = _offered(channels);
    final channel = _channel(channels);
    return AuroraScaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          // En-tête émeraude : logo brillant posé sur un miroir.
          ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(40)),
            child: AuroraBackground(
              tone: AuroraTone.deep,
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, top + 36, 24, 64),
                child: const Column(
                  children: [
                    MirrorReflection(size: 76, child: BrandMark(size: 76)),
                    SizedBox(height: 6),
                    SamaLogo(size: 34, onDark: true),
                    SizedBox(height: 6),
                    Text(
                      'Un seul compte. Plusieurs services.',
                      style: TextStyle(color: Color(0xFFCDE9DD), fontSize: 15),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -36),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Glass(
                radius: 28,
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Votre numéro de téléphone',
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Nous vous envoyons un code de connexion ${channel.by}.',
                      key: const Key('otp_channel_text'),
                      style: TextStyle(color: AppColors.muted),
                    ),
                    if (offered.length > 1) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text('Recevoir le code par', style: TextStyle(color: AppColors.muted, fontSize: 13)),
                          const SizedBox(width: 10),
                          for (final c in offered) ...[
                            Pill(
                              key: Key('otp_by_${c.name}'),
                              label: c.label,
                              selected: c == channel,
                              onTap: () => ref.read(preferredOtpChannelProvider.notifier).set(c),
                            ),
                            const SizedBox(width: 6),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    CountryPills(
                      value: ref.watch(loginCountryProvider),
                      onChanged: (c) => setState(() {
                        ref.read(loginCountryProvider.notifier).set(c);
                        _error = null;
                      }),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const Key('phone'),
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      autofocus: true,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[\d ]')),
                        LengthLimitingTextInputFormatter(14),
                      ],
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 0.5),
                      decoration: InputDecoration(
                        labelText: 'Numéro',
                        hintText: ref.watch(loginCountryProvider).example,
                        prefixText: '+${ref.watch(loginCountryProvider).dial}  ',
                        errorText: _error,
                        errorMaxLines: 3,
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 18),
                    BusyButton(label: 'Recevoir le code', busy: _busy, onPressed: _submit),
                    if (showServerSetting) ...[
                      const SizedBox(height: 6),
                      TextButton.icon(
                        key: const Key('server_setting'),
                        onPressed: () => editServerUrl(context, ref),
                        icon: const Icon(Icons.dns_rounded, size: 16),
                        label: Text(
                          'Serveur : ${ref.watch(serverUrlProvider).replaceFirst(RegExp(r'^https?://'), '')}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Étape 2 : code à 6 chiffres.
class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, required this.target});
  final OtpTarget target;
  String get phone => target.phone;
  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

/// Renvoi par le même moyen : 1 minute ; changer de moyen (WhatsApp → SMS…) : 15 secondes.
const _resendAfter = 60;
const _switchAfter = 15;

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  int _elapsed = 0;
  Timer? _timer;
  late OtpChannel _channel = widget.target.channel;
  OtpChannel? _sending;

  int get _wait => (_resendAfter - _elapsed).clamp(0, _resendAfter);

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    setState(() => _elapsed = 0);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _elapsed++);
      if (_elapsed >= _resendAfter) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_code.text.length != 6) {
      setState(() => _error = 'Le code contient 6 chiffres');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // La redirection du routeur prend le relais une fois connecté.
      await ref.read(authProvider.notifier).verifyOtp(widget.phone, _code.text);
    } on ApiException catch (e) {
      final left = e.detailInt('remainingAttempts');
      setState(() => _error = left != null ? '${e.message} — $left essai(s) restant(s)' : e.message);
      _code.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Renvoie le code, par le même moyen ou par un autre (« Pas reçu ? »).
  Future<void> _resend([OtpChannel? channel]) async {
    final c = channel ?? _channel;
    setState(() => _sending = c);
    try {
      final sent = await ref.read(authProvider.notifier).requestOtp(widget.phone, channel: c);
      if (!mounted) return;
      setState(() => _channel = sent.channel);
      if (sent.channel != OtpChannel.call) await ref.read(preferredOtpChannelProvider.notifier).set(sent.channel);
      _startTimer();
      if (mounted) showInfo(context, 'Nouveau code envoyé ${sent.channel.by}');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  String get _tip => switch (_channel) {
    OtpChannel.whatsapp => 'Ouvrez WhatsApp : le code arrive dans un message.',
    OtpChannel.call => 'Décrochez : une voix vous dicte le code.',
    OtpChannel.sms => 'Le code arrive par SMS dans quelques secondes.',
  };

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            const Text('Code de connexion', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              'Envoyé ${_channel.by} au ${intlPhone(widget.phone)}',
              key: const Key('otp_sent_to'),
              style: TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 2),
            Text(_tip, style: TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 24),
            TextField(
              key: const Key('code'),
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 12),
              decoration: InputDecoration(hintText: '••••••', errorText: _error, errorMaxLines: 3),
              onChanged: (v) {
                if (v.length == 6) _verify();
              },
            ),
            const SizedBox(height: 20),
            BusyButton(label: 'Valider', busy: _busy, onPressed: _verify),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('otp_resend'),
              onPressed: _wait == 0 && _sending == null ? () => _resend() : null,
              child: Text(_wait == 0 ? 'Renvoyer le code' : 'Renvoyer le code dans $_wait s'),
            ),
            if (widget.target.channels.length > 1) ...[
              const SizedBox(height: 14),
              Text(
                'Pas reçu ?',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink),
              ),
              const SizedBox(height: 8),
              for (final c in widget.target.channels.where((c) => c != _channel))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton.icon(
                    key: Key('otp_switch_${c.name}'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: _elapsed >= _switchAfter && _sending == null ? () => _resend(c) : null,
                    icon: _sending == c
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(switch (c) {
                            OtpChannel.whatsapp => Icons.chat_rounded,
                            OtpChannel.sms => Icons.sms_rounded,
                            OtpChannel.call => Icons.phone_in_talk_rounded,
                          }),
                    label: Text(
                      _elapsed >= _switchAfter ? c.action : '${c.action} (${_switchAfter - _elapsed} s)',
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Étape 3 (première connexion) : nom.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});
  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _name = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().length < 2) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).saveName(_name.text);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            const Text('Bienvenue sur Sama360', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('Comment vous appelez-vous ?', style: TextStyle(color: AppColors.muted, fontSize: 15)),
            const SizedBox(height: 24),
            TextField(
              key: const Key('fullName'),
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Prénom et nom'),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 20),
            BusyButton(label: 'Continuer', busy: _busy, onPressed: _save),
          ],
        ),
      ),
    );
  }
}

/// Réglage du serveur visible tant que l'app n'est pas publiée sur les stores
/// (`--dart-define=STORE=true` pour le masquer).
const showServerSetting = !bool.fromEnvironment('STORE');

/// Adresse du serveur (ex. le PC sur le même Wi-Fi : http://192.168.1.20:3000), vérifiée avant d'être gardée.
Future<void> editServerUrl(BuildContext context, WidgetRef ref) async {
  final ctrl = TextEditingController(text: ref.read(serverUrlProvider));
  String? error;
  var testing = false;
  final saved = await showDialog<String?>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Serveur Sama360'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pour les tests : l’adresse du PC qui fait tourner l’API, sur le même Wi-Fi que le téléphone.',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('server_url'),
              controller: ctrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(hintText: 'http://192.168.1.20:3000', errorText: error, errorMaxLines: 3),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Par défaut')),
          CancelButton(onPressed: () => Navigator.pop(ctx)),
          ConfirmButton(
            label: testing ? 'Test…' : 'Enregistrer',
            onPressed: () async {
              var url = ctrl.text.trim().replaceAll(RegExp(r'/+$'), '');
              if (!url.startsWith('http')) url = 'http://$url';
              setState(() {
                testing = true;
                error = null;
              });
              final ok = await serverReachable(url);
              if (!ctx.mounted) return;
              if (ok) {
                Navigator.pop(ctx, url);
              } else {
                setState(() {
                  testing = false;
                  error = 'Pas de réponse de $url/health. Vérifiez l’adresse, le Wi-Fi et que l’API tourne.';
                });
              }
            },
          ),
        ],
      ),
    ),
  );
  // Pas de dispose immédiat : le dialogue se ferme encore en animation avec ce contrôleur.
  if (saved == null) return;
  await ref.read(serverUrlProvider.notifier).set(saved.isEmpty ? null : saved);
  if (context.mounted) showInfo(context, saved.isEmpty ? 'Serveur par défaut' : 'Serveur enregistré');
}

/// Le serveur répond-il à /health ? (remplaçable dans les tests)
Future<bool> Function(String url) serverReachable = (url) async {
  try {
    final r = await Dio(
      BaseOptions(connectTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 5)),
    ).get<dynamic>('$url/health');
    return r.statusCode == 200;
  } catch (_) {
    return false;
  }
};
