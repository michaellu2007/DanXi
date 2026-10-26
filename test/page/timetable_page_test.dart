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

import 'dart:convert';

import 'package:dan_xi/generated/l10n.dart';
import 'package:dan_xi/model/person.dart';
import 'package:dan_xi/page/subpage_timetable.dart';
import 'package:dan_xi/provider/settings_provider.dart';
import 'package:dan_xi/provider/state_provider.dart';
import 'package:dan_xi/repository/fdu/time_table_repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object> courseJson(String id, String name, String room,
        int weekday, int startSlot, int endSlot) =>
    {
      "teacherNames": ["T"],
      "courseId": id,
      "courseName": name,
      "roomId": room,
      "roomName": room,
      "availableWeeks": [1, 2, 3],
      "times": [
        for (int s = startSlot; s <= endSlot; s++)
          {"weekDay": weekday, "slot": s}
      ],
    };

/// Full-page regression test for the drag & delete interactions.
///
/// Seeds the timetable cache with Course S (Mon, slot 3-4) and Course F
/// (Thu, slot 11-12), then drags S down one slot and deletes it through the
/// long-press menu. Guards against two former bugs: a leftover at the drag
/// origin (missing event merge in convertToBlock) and a blank page after
/// deleting (menu items popping the root route twice).
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => switch (call.method) {
            'read' => '0123456789abcdef',
            'readAll' => <String, String>{},
            'containsKey' => true,
            _ => null,
          },
    );
    final DateTime monday =
        DateTime.now().subtract(Duration(days: DateTime.now().weekday - 1));
    final tableJson = {
      "startTime": monday.toIso8601String(),
      "courses": [
        courseJson("S", "CourseS", "R101", 0, 2, 3),
        courseJson("F", "CourseF", "R202", 3, 10, 11),
      ],
    };
    SharedPreferences.setMockInitialValues({
      TimeTableRepository.KEY_TIMETABLE_CACHE: json.encode(tableJson),
      "visited_timetable": true,
    });
    await SettingsProvider.getInstance().init();
    StateProvider.personInfo.value = PersonInfo(
        "testid", "pwd", "tester", UserGroup.FUDAN_UNDERGRADUATE_STUDENT);
  });

  testWidgets('drag down then delete works without leftovers or blank page',
      (tester) async {
    // Tall surface so the whole grid is visible without scrolling.
    tester.view.physicalSize = const Size(800 * 3, 1600 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        S.delegate,
      ],
      supportedLocales: S.delegate.supportedLocales,
      home: ChangeNotifierProvider<SettingsProvider>.value(
        value: SettingsProvider.getInstance(),
        child: const Scaffold(body: TimetableSubPage()),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text("CourseS"), findsOneWidget);
    Finder cardOf(String name) => find
        .ancestor(of: find.text(name), matching: find.byType(AspectRatio))
        .first;
    Offset cardTop(String name) => tester.getTopLeft(cardOf(name));
    // Grid geometry: 6 columns -> cell width 133.3, row height 125, and the
    // week bar above the grid totals 173px.
    expect(cardTop("CourseS").dx, closeTo(133.3, 0.5));
    expect(cardTop("CourseS").dy, closeTo(423, 0.5));

    // --- Long-press CourseS and drag it down by exactly one slot ---
    final Offset blockCenter = const Offset(200, 548);
    final gesture = await tester.startGesture(blockCenter);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(blockCenter + const Offset(0, 125));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Exactly one card remains (no leftover at the origin) and it sits one
    // row lower.
    expect(find.text("CourseS"), findsOneWidget);
    expect(cardTop("CourseS").dy, closeTo(548, 0.5));

    // --- Long-press without moving -> menu -> delete -> confirm ---
    final gesture2 = await tester.startGesture(const Offset(200, 750));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture2.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(S.current.delete_course), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text(S.current.delete_course),
      200,
      scrollable: find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(Scrollable)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text(S.current.delete_course));
    await tester.pump(const Duration(milliseconds: 600));

    // The course is synced, so the confirm dialog explains local hiding.
    expect(find.text(S.current.ok), findsWidgets);
    await tester.tap(find.text(S.current.ok).last);
    await tester.pump();
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // The page must still render: the deleted course is gone (hidden
    // locally) while the untouched course remains visible.
    expect(find.text("CourseS"), findsNothing);
    expect(find.text("CourseF"), findsOneWidget);
  });
}
