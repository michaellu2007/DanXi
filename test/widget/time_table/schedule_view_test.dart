/*
 *     Copyright (C) 2021  DanXi-Dev
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'package:dan_xi/generated/l10n.dart';
import 'package:dan_xi/model/time_table.dart';
import 'package:dan_xi/provider/settings_provider.dart';
import 'package:dan_xi/widget/time_table/day_events.dart';
import 'package:dan_xi/widget/time_table/schedule_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sample table (Mon-Fri, 3 slots):
/// - Course A: Monday, slot 1-2 (a two-slot block)
/// - Course B: Wednesday, slot 1
List<DayEvents> buildLanes() {
  Course courseA = Course()
    ..courseId = "A"
    ..courseName = "CourseA"
    ..roomName = "R101"
    ..roomId = "1"
    ..availableWeeks = [1]
    ..times = [CourseTime(0, 0), CourseTime(0, 1)];
  Course courseB = Course()
    ..courseId = "B"
    ..courseName = "CourseB"
    ..roomName = "R202"
    ..roomId = "2"
    ..availableWeeks = [1]
    ..times = [CourseTime(2, 0)];
  Event event(Course c, int slot) => Event(c, CourseTime(c.times!.first.weekDay, slot));
  return [
    DayEvents(day: "Mon", weekday: 0, events: [event(courseA, 0), event(courseA, 1)]),
    DayEvents(day: "Tue", weekday: 1, events: []),
    DayEvents(day: "Wed", weekday: 2, events: [event(courseB, 0)]),
    DayEvents(day: "Thu", weekday: 3, events: []),
    DayEvents(day: "Fri", weekday: 4, events: []),
  ];
}

Future<void> pumpTable(WidgetTester tester,
    {OnMoveCourseCallback? onMove, OnLongPressCourseCallback? onLongPress, Map<String, String>? notes}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      S.delegate,
    ],
    supportedLocales: S.delegate.supportedLocales,
    home: Scaffold(
      // The real page embeds ScheduleView in a ListView (unbounded main axis).
      // Under a bounded constraint the grid stretches its auto rows and the
      // drag geometry changes, so keep the production layout here.
      body: ListView(
        children: [
          ScheduleView(
            buildLanes(),
            const TimetableStyle(),
            TimeNow(1, 0, 0),
            1,
            courseNotes: notes,
            moveCallback: onMove,
            longPressCallback: onLongPress,
          ),
        ],
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Grid geometry on the 800x600 test surface with 5 lanes:
/// cell width = 800 / 6 ~= 133.33, row height = 125.
Offset cellCenter(int day, int slot) =>
    Offset((1 + day) * 800 / 6 + 800 / 12, (slot + 1) * 125 + 62.5);

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        switch (call.method) {
          case 'read':
            return '0123456789abcdef';
          case 'readAll':
            return <String, String>{};
          case 'containsKey':
            return true;
          default:
            return null;
        }
      },
    );
    SharedPreferences.setMockInitialValues({});
    await SettingsProvider.getInstance().init();
  });

  testWidgets('dragging a block to a free area reports the move',
      (tester) async {
    final moves = <(int, int)>[];
    await pumpTable(tester,
        onMove: (block, day, firstSlot) => moves.add((day, firstSlot)));

    // Long-press the two-slot Course A block (Mon, slot 1-2).
    final gesture = await tester.startGesture(cellCenter(0, 0));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    // Drag to the Tuesday column, same rows.
    await gesture.moveTo(cellCenter(1, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(moves, equals([(1, 0)]));
  });

  testWidgets('dropping onto an occupied cell is rejected',
      (tester) async {
    final moves = <(int, int)>[];
    await pumpTable(tester,
        onMove: (block, day, firstSlot) => moves.add((day, firstSlot)));

    // Drag Course B (Wed, slot 1) onto Course A's area (Mon, slot 1-2).
    final gesture = await tester.startGesture(cellCenter(2, 0));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(cellCenter(0, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(moves, isEmpty);
  });

  testWidgets('long-press without moving opens the menu callback',
      (tester) async {
    final longPresses = <int>[];
    final moves = <(int, int)>[];
    await pumpTable(tester,
        onMove: (block, day, firstSlot) => moves.add((day, firstSlot)),
        onLongPress: (block, day) => longPresses.add(day));

    final gesture = await tester.startGesture(cellCenter(0, 0));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(longPresses, equals([0]));
    expect(moves, isEmpty);
  });

  testWidgets('course note is rendered on the card', (tester) async {
    await pumpTable(tester, notes: {"A": "Bring lab report"});
    expect(find.text("Bring lab report"), findsOneWidget);
  });
}
