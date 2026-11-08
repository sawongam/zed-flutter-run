import 'package:flutter_run/src/dap/session_phase.dart';
import 'package:test/test.dart';

void main() {
  group('SessionPhaseMachine', () {
    test('starts in starting and walks forward', () {
      final m = SessionPhaseMachine(strict: true);
      expect(m.phase, SessionPhase.starting);
      expect(m.transition(SessionPhase.running), isTrue);
      m.beginStopping();
      expect(m.phase, SessionPhase.stopping);
      expect(m.isStopping, isTrue);
      expect(m.isFinishing, isFalse);
      expect(m.transition(SessionPhase.finishing), isTrue);
      expect(m.isFinishing, isTrue);
      expect(m.isFinished, isFalse);
      expect(m.transition(SessionPhase.finished), isTrue);
      expect(m.isFinished, isTrue);
    });

    test('a crash may finish straight from running', () {
      final m = SessionPhaseMachine(strict: true)
        ..transition(SessionPhase.running);
      expect(m.transition(SessionPhase.finishing), isTrue);
      expect(m.isStopping, isTrue, reason: 'finishing counts as past stopping');
    });

    test('the legal table is forward-only', () {
      for (final entry in SessionPhaseMachine.legal.entries) {
        for (final to in entry.value) {
          expect(to.index, greaterThan(entry.key.index));
        }
      }
      expect(SessionPhaseMachine.legal[SessionPhase.finished], isEmpty);
    });

    test('a backward move is ignored and does not change the phase', () {
      final m = SessionPhaseMachine()
        ..transition(SessionPhase.running)
        ..transition(SessionPhase.finishing);
      expect(m.transition(SessionPhase.running), isFalse);
      expect(m.phase, SessionPhase.finishing);
    });

    test('an illegal move trips the assertion in strict mode', () {
      final m = SessionPhaseMachine(strict: true);
      expect(
        () => m.transition(SessionPhase.finished),
        throwsA(isA<AssertionError>()),
      );
    });

    test('moving to the current phase is a quiet no-op', () {
      final m = SessionPhaseMachine(strict: true)
        ..transition(SessionPhase.running);
      expect(m.transition(SessionPhase.running), isFalse);
    });

    test('beginStopping only acts while running', () {
      final m = SessionPhaseMachine(strict: true)..beginStopping();
      expect(m.phase, SessionPhase.starting);
      m
        ..transition(SessionPhase.running)
        ..beginStopping()
        ..beginStopping();
      expect(m.phase, SessionPhase.stopping);
      m
        ..transition(SessionPhase.finishing)
        ..beginStopping();
      expect(m.phase, SessionPhase.finishing);
    });
  });
}
