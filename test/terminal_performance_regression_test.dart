import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:python_runner/features/console/presentation/widgets/terminal_view.dart';
import 'package:python_runner/models/log_entry.dart';
import 'package:python_runner/utils/app_page_transitions.dart';
import 'package:shared_preferences/shared_preferences.dart';

LogEntry entry(String text) =>
    LogEntry(type: LogType.stdout, content: text, timestamp: DateTime(2026));

Finder line(String text) => find.byWidgetPredicate(
  (widget) => widget is Text && widget.textSpan?.toPlainText() == text,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('line index handles append, replacement, trim and CRLF', (
    tester,
  ) async {
    var logs = [entry('first\r\nsecond\n'), entry('tail')];
    var version = 0;
    Widget app() => MaterialApp(
      home: Scaffold(
        body: TerminalView(
          logs: logs,
          logVersion: version,
          autoFollowInitiallyEnabled: false,
        ),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(line('first'), findsOneWidget);
    expect(line('second'), findsOneWidget);
    expect(line('\u200B'), findsOneWidget);
    expect(line('tail'), findsOneWidget);

    logs = [...logs, entry('added')];
    version++;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(line('added'), findsOneWidget);

    // Mutating the same list is supported when the version advances.
    logs[1] = entry('replacement\nextra');
    version++;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(line('tail'), findsNothing);
    expect(line('replacement'), findsOneWidget);
    expect(line('extra'), findsOneWidget);

    logs = [logs.last];
    version++;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(line('first'), findsNothing);
    expect(line('added'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large multiline output keeps sliver children virtualized', (
    tester,
  ) async {
    final content = List.generate(10000, (i) => 'line $i').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            logs: [entry(content)],
            autoFollowInitiallyEnabled: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView));
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 10000);
    expect(line('line 0'), findsOneWidget);
    expect(line('line 9999'), findsNothing);
    expect(
      find
          .byWidgetPredicate(
            (w) =>
                w is Text &&
                (w.textSpan?.toPlainText().startsWith('line ') ?? false),
          )
          .evaluate()
          .length,
      lessThan(200),
    );
  });

  testWidgets('viewport updates do not override paused following', (
    tester,
  ) async {
    final key = GlobalKey<TerminalViewState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            key: key,
            logs: List.generate(200, (i) => entry('line $i')),
            autoFollowInitiallyEnabled: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final position = tester
        .widget<ListView>(find.byType(ListView))
        .controller!
        .position;
    expect(position.pixels, 0);
    key.currentState!.followViewportIfEnabled();
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
  });

  testWidgets('terminal route has no overlapping animation on push or pop', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('source page')),
      ),
    );
    final route = AppPageTransitions.terminal<void>(
      const Scaffold(body: Text('terminal page')),
    );
    final pageRoute = route as PageRoute<void>;
    expect(pageRoute.transitionDuration, Duration.zero);
    expect(pageRoute.reverseTransitionDuration, Duration.zero);
    navigator.currentState!.push(route);
    await tester.pumpAndSettle();
    expect(find.text('terminal page'), findsOneWidget);
    expect(find.text('source page'), findsNothing);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('source page'), findsOneWidget);
    expect(find.text('terminal page'), findsNothing);
  });
}
