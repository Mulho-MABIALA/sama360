import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/pin_lock.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../home/monument.dart';
import 'auth_controller.dart';

enum PinMode { unlock, create, change }

enum _Step { current, enter, confirm }

/// Écran du code secret : déverrouiller, créer ou changer (pavé numérique façon Wave / Orange Money).
class PinScreen extends ConsumerStatefulWidget {
  const PinScreen({super.key, required this.mode, this.firstName});
  final PinMode mode;
  final String? firstName;

  @override
  ConsumerState<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends ConsumerState<PinScreen> with SingleTickerProviderStateMixin {
  late _Step _step = widget.mode == PinMode.change
      ? _Step.current
      : widget.mode == PinMode.create
      ? _Step.enter
      : _Step.current;
  String _digits = '';
  String? _first;
  String? _error;
  bool _busy = false;
  bool _confirmForgot = false;
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  String get _title => switch ((widget.mode, _step)) {
    (PinMode.unlock, _) => widget.firstName == null ? 'Bon retour !' : 'Bonjour ${widget.firstName}',
    (PinMode.change, _Step.current) => 'Code secret actuel',
    (_, _Step.enter) => widget.mode == PinMode.change ? 'Nouveau code secret' : 'Créez votre code secret',
    (_, _Step.confirm) => 'Confirmez votre code',
    _ => '',
  };

  String get _subtitle => switch ((widget.mode, _step)) {
    (PinMode.unlock, _) => 'Entrez votre code secret',
    (PinMode.change, _Step.current) => 'Pour confirmer que c’est bien vous',
    (_, _Step.enter) => '4 chiffres pour ouvrir l’app en toute sécurité',
    (_, _Step.confirm) => 'Tapez-le encore une fois',
    _ => '',
  };

  void _fail(String message) {
    HapticFeedback.heavyImpact();
    _shake.forward(from: 0);
    setState(() {
      _error = message;
      _digits = '';
    });
  }

  void _tap(String d) {
    if (_busy || _digits.length >= pinLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _digits += d;
      _error = null;
    });
    if (_digits.length == pinLength) _submit(_digits);
  }

  void _erase() {
    if (_busy || _digits.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  Future<void> _submit(String pin) async {
    // Laisse le 4e point s'afficher avant de vérifier
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    final lock = ref.read(pinLockProvider.notifier);
    try {
      await _run(lock, pin);
    } catch (e) {
      // Jamais d'écran figé : on dit ce qui ne va pas et on laisse recommencer
      if (!mounted) return;
      setState(() => _busy = false);
      _fail('Impossible d’enregistrer le code sur cet appareil. Réessayez.');
      debugPrint('Code secret : $e');
    }
  }

  Future<void> _run(PinLockController lock, String pin) async {
    switch (_step) {
      case _Step.current when widget.mode == PinMode.unlock:
        setState(() => _busy = true);
        final r = await lock.verify(pin);
        if (!mounted) return;
        setState(() => _busy = false);
        if (r == PinCheck.ok) {
          HapticFeedback.mediumImpact();
        } else if (r == PinCheck.blocked) {
          await _signOut();
        } else {
          final left = ref.read(pinLockProvider).attemptsLeft;
          _fail(left <= 3 ? 'Code incorrect. Plus que $left essai${left > 1 ? 's' : ''}.' : 'Code incorrect.');
        }
      case _Step.current:
        setState(() => _busy = true);
        final ok = await lock.matches(pin);
        if (!mounted) return;
        setState(() => _busy = false);
        if (ok) {
          setState(() {
            _step = _Step.enter;
            _digits = '';
          });
        } else {
          _fail('Code incorrect.');
        }
      case _Step.enter:
        final weak = weakPinReason(pin);
        if (weak != null) {
          _fail(weak);
          return;
        }
        setState(() {
          _first = pin;
          _step = _Step.confirm;
          _digits = '';
        });
      case _Step.confirm:
        if (pin != _first) {
          _fail('Les deux codes ne correspondent pas. Recommencez.');
          setState(() {
            _step = _Step.enter;
            _first = null;
          });
          return;
        }
        final userId = ref.read(authProvider).value?.me?.id;
        if (userId == null) {
          _fail('Session expirée. Reconnectez-vous.');
          return;
        }
        setState(() => _busy = true);
        await lock.setPin(userId, pin);
        if (!mounted) return;
        setState(() => _busy = false);
        HapticFeedback.mediumImpact();
        if (widget.mode == PinMode.change) {
          showInfo(context, 'Code secret modifié');
          context.pop();
        }
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    await ref.read(authProvider.notifier).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final unlock = widget.mode == PinMode.unlock;
    // Ouverture et création : monument du jour en fond, touches en verre (comme l'accueil)
    final photo = widget.mode != PinMode.change;
    final ink = photo ? Colors.white : AppColors.ink;
    final soft = photo ? Colors.white.withValues(alpha: 0.85) : AppColors.muted;
    final errorColor = photo ? const Color(0xFFFFB4A8) : AppColors.danger;
    final screen = Scaffold(
      backgroundColor: photo ? Colors.transparent : AppColors.ground,
      appBar: widget.mode == PinMode.change
          ? AppBar(backgroundColor: Colors.transparent, title: const Text('Code secret'))
          : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final compact = box.maxHeight < 760;
            // Touches à la taille de l'écran : plus de débordement sur petit écran ou fenêtre basse
            final header = compact ? 232.0 : 290.0;
            final keySize = ((box.maxHeight - header - 76) / 4 - 10).clamp(44.0, 76.0);
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  children: [
                    SizedBox(height: compact ? 16 : 40),
                    BrandMark(size: compact ? 52 : 64),
                    SizedBox(height: compact ? 14 : 20),
                    Text(
                      _title,
                      key: const Key('pin_title'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: ink,
                        shadows: photo ? const [Shadow(color: Color(0x80000000), blurRadius: 14)] : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: soft,
                        shadows: photo ? const [Shadow(color: Color(0x80000000), blurRadius: 10)] : null,
                      ),
                    ),
                    SizedBox(height: compact ? 22 : 34),
                    AnimatedBuilder(
                      animation: _shake,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(math.sin(_shake.value * math.pi * 6) * 12 * (1 - _shake.value), 0),
                        child: child,
                      ),
                      child: _Dots(filled: _digits.length, error: _error != null, onPhoto: photo),
                    ),
                    SizedBox(
                      height: 44,
                      child: Center(
                        child: _busy
                            ? SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: photo ? Colors.white : AppColors.green,
                                ),
                              )
                            : _error == null
                            ? null
                            : Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24),
                                child: Text(
                                  _error!,
                                  key: const Key('pin_error'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: errorColor, fontWeight: FontWeight.w700, fontSize: 13),
                                ),
                              ),
                      ),
                    ),
                    const Spacer(),
                    if (_confirmForgot)
                      _ForgotPanel(onCancel: () => setState(() => _confirmForgot = false), onConfirm: _signOut)
                    else ...[
                      _Keypad(onDigit: _tap, onErase: _erase, keySize: keySize, glass: photo),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 48,
                        child: unlock
                            ? TextButton(
                                onPressed: _busy ? null : () => setState(() => _confirmForgot = true),
                                child: Text(
                                  'Code secret oublié ?',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                    color: photo ? Colors.white : null,
                                  ),
                                ),
                              )
                            : widget.mode == PinMode.create
                            ? TextButton(
                                onPressed: _busy ? null : _signOut,
                                child: Text('Se déconnecter', style: TextStyle(color: soft)),
                              )
                            : null,
                      ),
                    ],
                    SizedBox(height: compact ? 8 : 16),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    if (!photo) return screen;
    return Stack(
      fit: StackFit.expand,
      children: [
        const MonumentBackdrop(),
        // Voile plus marqué en bas : le pavé reste lisible sur toutes les photos
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, 0.45, 1],
              colors: [Color(0x26000000), Color(0x40052A1F), Color(0xA6052A1F)],
            ),
          ),
        ),
        screen,
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.filled, required this.error, this.onPhoto = false});
  final int filled;
  final bool error;
  final bool onPhoto;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$filled chiffre${filled > 1 ? 's' : ''} sur $pinLength',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < pinLength; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            margin: const EdgeInsets.symmetric(horizontal: 9),
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: onPhoto
                  ? (i < filled
                        ? (error ? const Color(0xFFFFB4A8) : Colors.white)
                        : Colors.white.withValues(alpha: 0.18))
                  : i < filled
                  ? (error ? AppColors.danger : AppColors.green)
                  : (error ? AppColors.danger.withValues(alpha: 0.25) : AppColors.green.withValues(alpha: 0.22)),
              border: onPhoto ? Border.all(color: Colors.white.withValues(alpha: 0.75), width: 1.5) : null,
            ),
          ),
      ],
    ),
  );
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onErase, required this.keySize, this.glass = false});
  final ValueChanged<String> onDigit;
  final VoidCallback onErase;
  final double keySize;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final color = glass ? Colors.white : AppColors.ink;
    Widget key(String d) => _Key(
      size: keySize,
      label: d,
      glass: glass,
      onTap: () => onDigit(d),
      child: Text(
        d,
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: color),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        children: [
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [for (final d in row) key(d)]),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SizedBox(width: keySize, height: keySize),
              key('0'),
              // Effacer : sans bulle, pour bien le distinguer des chiffres
              _Key(
                size: keySize,
                label: 'Effacer',
                onTap: onErase,
                child: Icon(Icons.backspace_rounded, size: 26, color: color),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.size, required this.label, required this.onTap, required this.child, this.glass = false});
  final double size;
  final String label;
  final VoidCallback onTap;
  final Widget child;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final tap = InkResponse(
      key: Key('pin_key_$label'),
      onTap: onTap,
      radius: size / 2,
      highlightShape: BoxShape.circle,
      highlightColor: glass ? Colors.white.withValues(alpha: 0.22) : null,
      splashColor: glass ? Colors.white.withValues(alpha: 0.28) : null,
      child: SizedBox(
        width: size,
        height: size,
        child: Center(child: child),
      ),
    );
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: !glass
            ? tap
            // Effet miroir : verre dépoli (la photo floutée dessous), reflet en haut à gauche, liseré clair
            : ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Colors.white.withValues(alpha: 0.32), Colors.white.withValues(alpha: 0.08)],
                      ),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.38)),
                    ),
                    child: Material(type: MaterialType.transparency, child: tap),
                  ),
                ),
              ),
      ),
    );
  }
}

class _ForgotPanel extends StatelessWidget {
  const _ForgotPanel({required this.onCancel, required this.onConfirm});
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Glass(
      radius: 22,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Code secret oublié ?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 6),
          Text(
            'Vous allez être déconnecté. Reconnectez-vous avec le code reçu par SMS, '
            'puis choisissez un nouveau code secret.',
            style: TextStyle(color: AppColors.muted, height: 1.35),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: CancelButton(onPressed: onCancel)),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  key: const Key('forgot_confirm'),
                  onPressed: onConfirm,
                  child: const Text('Continuer'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Posé au-dessus de toute l'app : demande le code (ou sa création) une fois connecté.
/// L'app reste montée dessous : au déverrouillage, on retrouve l'écran où on était.
class PinGate extends ConsumerStatefulWidget {
  const PinGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<PinGate> createState() => _PinGateState();
}

class _PinGateState extends ConsumerState<PinGate> {
  late final AppLifecycleListener _life;
  DateTime? _hiddenAt;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(
      onHide: () => _hiddenAt = DateTime.now(),
      onShow: () {
        final at = _hiddenAt;
        _hiddenAt = null;
        if (at != null && DateTime.now().difference(at) >= pinRelockAfter) {
          ref.read(pinLockProvider.notifier).lock();
        }
      },
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget? gate;
    if (ref.watch(pinLockEnabledProvider)) {
      final me = ref.watch(authProvider).value?.me;
      if (me != null && !me.needsProfile) {
        final pin = ref.watch(pinLockProvider);
        final first = (me.fullName ?? '').trim().split(' ').first;
        if (!pin.ready) {
          gate = ColoredBox(color: AppColors.ground);
        } else if (!pin.hasPinFor(me.id)) {
          gate = const PinScreen(key: ValueKey('pin_create'), mode: PinMode.create);
        } else if (pin.locked) {
          gate = PinScreen(
            key: const ValueKey('pin_unlock'),
            mode: PinMode.unlock,
            firstName: first.isEmpty ? null : first,
          );
        }
      }
    }
    // Même structure dans tous les cas : l'app dessous n'est jamais reconstruite de zéro.
    return Stack(
      children: [
        Offstage(
          offstage: gate != null,
          child: TickerMode(enabled: gate == null, child: widget.child),
        ),
        if (gate != null) Positioned.fill(child: gate),
      ],
    );
  }
}
