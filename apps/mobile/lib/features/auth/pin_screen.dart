import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/pin_lock.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
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
        if (lock.matches(pin)) {
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
        if (userId == null) return;
        setState(() => _busy = true);
        await lock.setPin(userId, pin);
        if (!mounted) return;
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
    return Scaffold(
      backgroundColor: AppColors.ground,
      appBar: widget.mode == PinMode.change
          ? AppBar(backgroundColor: Colors.transparent, title: const Text('Code secret'))
          : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final compact = box.maxHeight < 640;
            return Column(
              children: [
                SizedBox(height: compact ? 16 : 40),
                BrandMark(size: compact ? 52 : 64),
                SizedBox(height: compact ? 14 : 20),
                Text(
                  _title,
                  key: const Key('pin_title'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  _subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted),
                ),
                SizedBox(height: compact ? 22 : 34),
                AnimatedBuilder(
                  animation: _shake,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(math.sin(_shake.value * math.pi * 6) * 12 * (1 - _shake.value), 0),
                    child: child,
                  ),
                  child: _Dots(filled: _digits.length, error: _error != null),
                ),
                SizedBox(
                  height: 44,
                  child: Center(
                    child: _error == null
                        ? null
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              _error!,
                              key: const Key('pin_error'),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700, fontSize: 13),
                            ),
                          ),
                  ),
                ),
                const Spacer(),
                if (_confirmForgot)
                  _ForgotPanel(onCancel: () => setState(() => _confirmForgot = false), onConfirm: _signOut)
                else ...[
                  _Keypad(onDigit: _tap, onErase: _erase, keySize: compact ? 64 : 74),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 48,
                    child: unlock
                        ? TextButton(
                            onPressed: _busy ? null : () => setState(() => _confirmForgot = true),
                            child: const Text(
                              'Code secret oublié ?',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                          )
                        : widget.mode == PinMode.create
                        ? TextButton(
                            onPressed: _busy ? null : _signOut,
                            child: Text('Se déconnecter', style: TextStyle(color: AppColors.muted)),
                          )
                        : null,
                  ),
                ],
                SizedBox(height: compact ? 8 : 16),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.filled, required this.error});
  final int filled;
  final bool error;

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
              color: i < filled
                  ? (error ? AppColors.danger : AppColors.green)
                  : (error ? AppColors.danger.withValues(alpha: 0.25) : AppColors.green.withValues(alpha: 0.22)),
            ),
          ),
      ],
    ),
  );
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onErase, required this.keySize});
  final ValueChanged<String> onDigit;
  final VoidCallback onErase;
  final double keySize;

  @override
  Widget build(BuildContext context) {
    Widget key(String d) => _Key(
      size: keySize,
      label: d,
      onTap: () => onDigit(d),
      child: Text(d, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
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
              _Key(
                size: keySize,
                label: 'Effacer',
                onTap: onErase,
                child: Icon(Icons.backspace_rounded, size: 26, color: AppColors.ink),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.size, required this.label, required this.onTap, required this.child});
  final double size;
  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkResponse(
        key: Key('pin_key_$label'),
        onTap: onTap,
        radius: size / 2,
        highlightShape: BoxShape.circle,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: child),
        ),
      ),
    ),
  );
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
